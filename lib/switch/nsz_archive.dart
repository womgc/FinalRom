import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:zstd_ffi/zstd_ffi.dart';

import 'aes_xts.dart';
import 'keys.dart';
import 'nca.dart';
import 'ncz.dart';
import 'pfs0.dart';

/// Orchestrates whole-archive NSP ↔ NSZ conversion: it walks a PFS0, runs the
/// per-NCA [Ncz] codec on the content members, passes everything else through
/// (tickets, certs, `.cnmt`), and rebuilds the container.
///
/// Compression needs the user's [SwitchKeys]; decompression needs no keys.
class NszArchive {
  static const int _minCompressibleNca = nczUncompressedHeaderSize;

  /// Compresses every NCA in [inputNspPath] (≥ 0x4000) to NCZ and writes a
  /// `.nsz` to [outputPath].
  static Future<void> compress({
    required String inputNspPath,
    required String outputPath,
    required SwitchKeys keys,
    int level = 18,
    int threadCount = 0,
    int chunkSizeMB = 2,
    bool nszParallel = true,
    int maxConcurrentNcas = 1 << 30,
    String? tempDirPath,
    void Function(String message, double fraction)? onProgress,
  }) async {
    final reader = await Pfs0Reader.open(inputNspPath);
    final source = await File(inputNspPath).open(mode: FileMode.read);
    final tempDir = await _createTempDir('nsz_compress_', tempDirPath);
    try {
      final tickets = await _loadTickets(reader);
      final builder = Pfs0Builder();

      final totalBytes =
          reader.entries.fold<int>(0, (sum, entry) => sum + entry.dataSize);
      var processedBytes = 0;
      final report = _throttledReporter(onProgress, () => processedBytes, totalBytes);

      final members = List<Pfs0Member?>.filled(reader.entries.length, null);
      final jobs = <Future<void>>[];
      // Cap how many NCA-compression isolates run at once. A single dominant NCA
      // (the common case) is unaffected, but a many-NCA merged archive would
      // otherwise spawn one isolate per NCA and exhaust RAM/CPU on weak devices.
      final ncaSlots = _Semaphore(maxConcurrentNcas < 1 ? 1 : maxConcurrentNcas);
      final progressPort = ReceivePort();

      progressPort.listen((msg) {
        if (msg is (String, int)) {
          final (name, delta) = msg;
          processedBytes += delta;
          report('Compressing $name');
        }
      });

      for (var index = 0; index < reader.entries.length; index++) {
        final entry = reader.entries[index];

        final isCompressibleNca = entry.name.toLowerCase().endsWith('.nca') &&
            entry.dataSize > _minCompressibleNca;
        if (!isCompressibleNca) {
          members[index] = Pfs0Member.fromFile(
            entry.name,
            inputNspPath,
            size: entry.dataSize,
            sourceOffset: entry.dataOffset,
          );
          processedBytes += entry.dataSize;
          report('Compressing ${entry.name}');
          continue;
        }

        final rawHeader =
            await _readAt(source, entry.dataOffset, Nca.headerEncryptedRegion);
        final xts = AesXts(keys.headerKey);
        final header = xts.decrypt(rawHeader);
        final rightsId = Uint8List.sublistView(header, 0x230, 0x240);
        final usesTitleKey = rightsId.any((byte) => byte != 0);
        final ticket = usesTitleKey ? tickets[_hex(rightsId)] : null;

        // Ncz.compress copies the verbatim header but only reports body bytes;
        // count the header here so the running total tracks dataSize.
        processedBytes += nczUncompressedHeaderSize;
        report('Compressing ${entry.name}');

        final tempPath = p.join(tempDir.path, '${entry.name}.ncz');

        if (nszParallel) {
          final isolateArgs = _NszCompressIsolateArgs(
            inputNspPath: inputNspPath,
            tempPath: tempPath,
            dataOffset: entry.dataOffset,
            dataSize: entry.dataSize,
            rawHeader: rawHeader,
            keys: keys,
            ticket: ticket,
            level: level,
            threadCount: threadCount,
            chunkSizeMB: chunkSizeMB,
            progressPort: progressPort.sendPort,
            entryName: entry.name,
          );
          jobs.add(() async {
            await ncaSlots.acquire();
            try {
              await _runIsolateJob(isolateArgs);
              members[index] = Pfs0Member.fromFile(
                _swapExtension(entry.name, '.ncz'),
                tempPath,
                size: await File(tempPath).length(),
              );
            } finally {
              ncaSlots.release();
            }
          }());
        } else {
          final nca = Nca.parse(
            rawHeader,
            keys,
            resolveTicket: (rightsId) => ticket,
          );
          final encoder = ZstdEncoder(
            level: level,
            workers: threadCount == 0 ? ZstdEncoder.defaultWorkerCount : threadCount,
          );
          final sink = File(tempPath).openWrite();
          try {
            await Ncz.compress(
              read: (offset, length) =>
                  _readAt(source, entry.dataOffset + offset, length),
              ncaSize: entry.dataSize,
              nca: nca,
              encoder: encoder,
              sink: sink,
              chunkSize: chunkSizeMB * 1024 * 1024,
              onBytes: (delta) {
                processedBytes += delta;
                report('Compressing ${entry.name}');
              },
            );
          } finally {
            await sink.flush();
            await sink.close();
            encoder.dispose();
          }

          members[index] = Pfs0Member.fromFile(
            _swapExtension(entry.name, '.ncz'),
            tempPath,
            size: await File(tempPath).length(),
          );
        }
      }

      if (jobs.isNotEmpty) {
        await Future.wait(jobs);
      }
      progressPort.close();

      for (final member in members) {
        if (member != null) {
          builder.add(member);
        }
      }

      await builder.writeTo(outputPath, onProgress: _assemblyReporter(onProgress, 'Assembling NSZ'));
      onProgress?.call('Done', 1.0);
    } finally {
      await source.close();
      await reader.close();
      await _cleanup(tempDir);
    }
  }

  static Future<void> _compressIsolate(_NszCompressIsolateArgs args) async {
    final source = await File(args.inputNspPath).open(mode: FileMode.read);
    try {
      final nca = Nca.parse(
        args.rawHeader,
        args.keys,
        resolveTicket: (rightsId) => args.ticket,
      );

      final encoder = ZstdEncoder(
        level: args.level,
        workers: args.threadCount == 0 ? ZstdEncoder.defaultWorkerCount : args.threadCount,
      );
      final sink = File(args.tempPath).openWrite();

      try {
        await Ncz.compress(
          read: (offset, length) =>
              _readAt(source, args.dataOffset + offset, length),
          ncaSize: args.dataSize,
          nca: nca,
          encoder: encoder,
          sink: sink,
          chunkSize: args.chunkSizeMB * 1024 * 1024,
          onBytes: (delta) {
            args.progressPort.send((args.entryName, delta));
          },
        );
      } finally {
        await sink.flush();
        await sink.close();
        encoder.dispose();
      }
    } finally {
      await source.close();
    }
  }

  static Future<void> _runIsolateJob(_NszCompressIsolateArgs args) {
    return Isolate.run(() => _compressIsolate(args));
  }

  /// Decompresses every NCZ in [inputNszPath] back to NCA and writes a `.nsp`
  /// to [outputPath]. No keys required.
  static Future<void> decompress({
    required String inputNszPath,
    required String outputPath,
    String? tempDirPath,
    void Function(String message, double fraction)? onProgress,
  }) async {
    final reader = await Pfs0Reader.open(inputNszPath);
    final source = await File(inputNszPath).open(mode: FileMode.read);
    final tempDir = await _createTempDir('nsz_decompress_', tempDirPath);
    try {
      final builder = Pfs0Builder();

      final totalBytes =
          reader.entries.fold<int>(0, (sum, entry) => sum + entry.dataSize);
      var processedBytes = 0;
      final report = _throttledReporter(onProgress, () => processedBytes, totalBytes);

      for (var index = 0; index < reader.entries.length; index++) {
        final entry = reader.entries[index];

        if (!Ncz.isNcz(entry.name)) {
          builder.add(Pfs0Member.fromFile(
            entry.name,
            inputNszPath,
            size: entry.dataSize,
            sourceOffset: entry.dataOffset,
          ));
          processedBytes += entry.dataSize;
          report('Decompressing ${entry.name}');
          continue;
        }

        final tempPath = p.join(tempDir.path, '${entry.name}.nca');
        final decoder = ZstdDecoder();
        final sink = File(tempPath).openWrite();
        // Ncz.decompress copies the verbatim header but only reports stream
        // bytes; count the header here so the running total tracks dataSize.
        processedBytes += nczUncompressedHeaderSize;
        report('Decompressing ${entry.name}');
        try {
          await Ncz.decompress(
            read: (offset, length) =>
                _readAt(source, entry.dataOffset + offset, length),
            nczSize: entry.dataSize,
            decoder: decoder,
            sink: sink,
            onBytes: (delta) {
              processedBytes += delta;
              report('Decompressing ${entry.name}');
            },
          );
        } finally {
          await sink.flush();
          await sink.close();
          decoder.dispose();
        }

        builder.add(Pfs0Member.fromFile(
          _swapExtension(entry.name, '.nca'),
          tempPath,
          size: await File(tempPath).length(),
        ));
      }

      await builder.writeTo(outputPath, onProgress: _assemblyReporter(onProgress, 'Assembling NSP'));
      onProgress?.call('Done', 1.0);
    } finally {
      await source.close();
      await reader.close();
      await _cleanup(tempDir);
    }
  }

  static Future<Map<String, SwitchTicket>> _loadTickets(
      Pfs0Reader reader) async {
    final tickets = <String, SwitchTicket>{};
    for (final entry in reader.entries) {
      if (!entry.name.toLowerCase().endsWith('.tik')) continue;
      final bytes = await reader.readEntry(entry);
      try {
        final ticket = SwitchTicket.parse(bytes);
        tickets[_hex(ticket.rightsId)] = ticket;
      } on SwitchKeysException {
        // Skip malformed tickets; titlekey NCAs needing them will surface a
        // clear error during parse.
      }
    }
    return tickets;
  }

  static Future<Uint8List> _readAt(
      RandomAccessFile file, int offset, int length) async {
    if (length == 0) return Uint8List(0);
    await file.setPosition(offset);
    final out = Uint8List(length);
    var read = 0;
    while (read < length) {
      final chunk = await file.read(length - read);
      if (chunk.isEmpty) {
        throw const FormatException('Unexpected end of archive while reading.');
      }
      out.setRange(read, read + chunk.length, chunk);
      read += chunk.length;
    }
    return out;
  }

  static String _swapExtension(String name, String newExtension) =>
      '${name.substring(0, name.lastIndexOf('.'))}$newExtension';

  static String _hex(Uint8List bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  static Future<void> _cleanup(Directory dir) async {
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {
      // Best-effort temp cleanup.
    }
  }

  /// Creates a unique temp dir under [base] when provided (e.g. a roomy
  /// external-cache dir on Android), otherwise under the system temp dir.
  static Future<Directory> _createTempDir(String prefix, String? base) async {
    if (base != null) {
      final root = Directory(base);
      await root.create(recursive: true);
      return root.createTemp(prefix);
    }
    return Directory.systemTemp.createTemp(prefix);
  }

  /// Builds a progress reporter that calls [onProgress] with a GB-formatted
  /// message and a [0, 1] fraction, throttled to whole-percent changes so a
  /// multi-GB run does not flood the UI isolate.
  static void Function(String message) _throttledReporter(
    void Function(String message, double fraction)? onProgress,
    int Function() processedBytes,
    int totalBytes,
  ) {
    var lastReportedPercent = -1;
    return (String message) {
      if (onProgress == null || totalBytes == 0) return;
      final fraction = (processedBytes() / totalBytes).clamp(0.0, 1.0);
      final percent = (fraction * 100).floor();
      if (percent == lastReportedPercent) return;
      lastReportedPercent = percent;
      final processedGb = processedBytes() / (1024 * 1024 * 1024);
      final totalGb = totalBytes / (1024 * 1024 * 1024);
      onProgress(
        '$message (${processedGb.toStringAsFixed(2)} / ${totalGb.toStringAsFixed(2)} GB)',
        fraction,
      );
    };
  }

  /// Builds the [Pfs0Builder.writeTo] progress callback for the final
  /// container-assembly phase, throttled to whole-percent changes.
  static void Function(int bytesWritten, int totalBytes)? _assemblyReporter(
    void Function(String message, double fraction)? onProgress,
    String message,
  ) {
    if (onProgress == null) return null;
    var lastReportedPercent = -1;
    return (int bytesWritten, int totalBytes) {
      if (totalBytes == 0) return;
      final fraction = (bytesWritten / totalBytes).clamp(0.0, 1.0);
      final percent = (fraction * 100).floor();
      if (percent == lastReportedPercent) return;
      lastReportedPercent = percent;
      onProgress(message, fraction);
    };
  }
}

/// Minimal counting semaphore used to bound concurrent NCA-compression
/// isolates. [acquire] resolves immediately while permits remain, otherwise it
/// queues until a [release].
class _Semaphore {
  int _permits;
  final _waiters = <Completer<void>>[];

  _Semaphore(this._permits);

  Future<void> acquire() {
    if (_permits > 0) {
      _permits--;
      return Future.value();
    }
    final completer = Completer<void>();
    _waiters.add(completer);
    return completer.future;
  }

  void release() {
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete();
    } else {
      _permits++;
    }
  }
}

class _NszCompressIsolateArgs {
  final String inputNspPath;
  final String tempPath;
  final int dataOffset;
  final int dataSize;
  final Uint8List rawHeader;
  final SwitchKeys keys;
  final SwitchTicket? ticket;
  final int level;
  final int threadCount;
  final int chunkSizeMB;
  final SendPort progressPort;
  final String entryName;

  _NszCompressIsolateArgs({
    required this.inputNspPath,
    required this.tempPath,
    required this.dataOffset,
    required this.dataSize,
    required this.rawHeader,
    required this.keys,
    required this.ticket,
    required this.level,
    required this.threadCount,
    required this.chunkSizeMB,
    required this.progressPort,
    required this.entryName,
  });
}

