import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:zstd_ffi/zstd_ffi.dart';

import '../io_tuning.dart';
import 'aes_xts.dart';
import 'hfs0.dart';
import 'keys.dart';
import 'nca.dart';
import 'ncz.dart';
import 'xci_reader.dart';

/// Python reference: `allign0x200(n) = 0x200 - n % 0x200`
/// This always adds padding, even when already 0x200-aligned.
int _pythonAlign0x200(int n) => 0x200 - (n % 0x200);

class XczArchive {
  static const int _minCompressibleNca = nczUncompressedHeaderSize;

  /// Compresses every NCA in [inputXciPath] (>= 0x4000) to NCZ and writes a
  /// `.xcz` to [outputPath].
  ///
  /// Mirrors Python's `solidCompressXci` from SolidCompressor.py:
  ///   - Copies the XCI header (up to hfs0Offset) verbatim.
  ///   - Builds a root Hfs0 with a 0x8000 reserved header.
  ///   - For each root partition, builds a nested Hfs0 (also 0x8000 header).
  ///   - Skips (writes dummy) update/normal partitions unless [keepPartitions].
  ///   - Aligns each partition to the next 0x200 boundary (Python-style: always
  ///     adds padding, even when already aligned).
  ///   - Seeks back to write finalized headers.
  static Future<void> compress({
    required String inputXciPath,
    required String outputPath,
    required SwitchKeys keys,
    int level = 18,
    int threadCount = 0,
    int chunkSizeMB = 2,
    bool keepPartitions = false,
    String? tempDirPath,
    void Function(String message, double fraction)? onProgress,
  }) async {
    final source = await File(inputXciPath).open(mode: FileMode.read);
    final output = await File(outputPath).open(mode: FileMode.write);
    final tempDir = await _createTempDir('xcz_compress_', tempDirPath);
    final reader = await XciReader.open(inputXciPath);

    try {
      // 1. Find root HFS0 offset from XCI header
      final hfs0Offset = await _findHfs0Offset(source);

      // 2. Copy XCI header verbatim (key area + cartridge header + certs)
      onProgress?.call('Copying XCI header', 0.0);
      await source.setPosition(0);
      var remainingHeader = hfs0Offset;
      while (remainingHeader > 0) {
        final take = remainingHeader < xczCopyChunkSize ? remainingHeader : xczCopyChunkSize;
        final bytes = await source.read(take);
        await output.writeFrom(bytes);
        remainingHeader -= bytes.length;
      }

      // 3. Compute total source bytes for progress reporting
      var totalBytes = 0;
      for (final partitionEntry in reader.rootHfs0.header.entries) {
        if (!keepPartitions && partitionEntry.name != 'secure') continue;
        final partitionSrcOffset = reader.rootHfs0.dataRegionOffset + partitionEntry.offset;
        final partitionReader = Hfs0Reader(source, partitionSrcOffset);
        await partitionReader.initialize();
        for (final fileEntry in partitionReader.header.entries) {
          totalBytes += fileEntry.size;
        }
      }
      var processedBytes = 0;

      // 4. Set up root Hfs0Builder. We manage entries manually so addFile()
      //    never seeks the shared file cursor at the wrong time.
      final rootBuilder = Hfs0Builder(file: output, startOffset: hfs0Offset);
      await rootBuilder.begin(); // seeks past the 0x8000 reserved header

      // Track the running write position relative to the root builder start
      // (same role as Python's `xci.hfs0.addpos`).
      var rootAddPos = rootBuilder.headerReservedSize;

      // 5. Iterate root partitions
      for (final partitionEntry in reader.rootHfs0.header.entries) {
        final isTrimmed = !keepPartitions && partitionEntry.name != 'secure';

        if (isTrimmed) {
          // Write a minimal valid HFS0 (0 files, 1-byte string table) padded to
          // one 0x200 media unit — matching the Python behaviour of keeping an
          // empty-but-valid placeholder.
          final dummy = ByteData(0x200);
          dummy.setUint8(0, 0x48); // 'H'
          dummy.setUint8(1, 0x46); // 'F'
          dummy.setUint8(2, 0x53); // 'S'
          dummy.setUint8(3, 0x30); // '0'
          dummy.setUint32(4, 0, Endian.little);  // fileCount = 0
          dummy.setUint32(8, 1, Endian.little);  // stringTableSize = 1
          dummy.setUint32(12, 0, Endian.little); // reserved
          await output.writeFrom(dummy.buffer.asUint8List());

          // Register in root builder (offset relative to data region start)
          rootBuilder.entries.add(Hfs0BuilderEntry(
            name: partitionEntry.name,
            size: 0x200,
            offset: rootAddPos - rootBuilder.headerReservedSize,
          ));
          rootAddPos += 0x200;
        } else {
          // Process partition contents
          final partitionSrcOffset = reader.rootHfs0.dataRegionOffset + partitionEntry.offset;
          final partitionSrcReader = Hfs0Reader(source, partitionSrcOffset);
          await partitionSrcReader.initialize();

          final tickets = await _loadTickets(partitionSrcReader);

          // The nested partition starts at the current write position
          final partitionStartInOutput = hfs0Offset + rootAddPos;
          final partitionBuilder = Hfs0Builder(
            file: output,
            startOffset: partitionStartInOutput,
          );
          await partitionBuilder.begin(); // seeks past inner 0x8000 reserved header

          for (final fileEntry in partitionSrcReader.header.entries) {
            final isCompressibleNca = fileEntry.name.toLowerCase().endsWith('.nca') &&
                fileEntry.size > _minCompressibleNca;

            if (isCompressibleNca) {
              // Compress NCA → NCZ via temp file, then stream into output
              final tempPath = p.join(tempDir.path, '${fileEntry.name}.ncz');
              final sink = File(tempPath).openWrite();

              final rawHeader = await partitionSrcReader.readEntry(
                fileEntry,
                offset: 0,
                length: Nca.headerEncryptedRegion,
              );

              final xts = AesXts(keys.headerKey);
              final decryptedHeader = xts.decrypt(rawHeader);
              final rightsId = Uint8List.sublistView(decryptedHeader, 0x230, 0x240);
              final usesTitleKey = rightsId.any((b) => b != 0);
              final ticket = usesTitleKey ? tickets[_hex(rightsId)] : null;

              final nca = Nca.parse(
                rawHeader,
                keys,
                resolveTicket: (_) => ticket,
              );

              final encoder = ZstdEncoder(
                level: level,
                workers: threadCount == 0 ? ZstdEncoder.defaultWorkerCount : threadCount,
              );

              try {
                await Ncz.compress(
                  read: (offset, length) => partitionSrcReader.readEntry(
                    fileEntry,
                    offset: offset,
                    length: length,
                  ),
                  ncaSize: fileEntry.size,
                  nca: nca,
                  encoder: encoder,
                  sink: sink,
                  chunkSize: chunkSizeMB * 1024 * 1024,
                  onBytes: (delta) {
                    processedBytes += delta;
                    onProgress?.call(
                      'Compressing ${fileEntry.name}',
                      (processedBytes / totalBytes).clamp(0.0, 1.0),
                    );
                  },
                );
              } finally {
                await sink.flush();
                await sink.close();
                encoder.dispose();
              }

              final nczName = _swapExtension(fileEntry.name, '.ncz');
              final compressedSize = await File(tempPath).length();

              // addFile seeks to the correct write position in the output
              await partitionBuilder.addFile(nczName, compressedSize);

              final tempFile = await File(tempPath).open(mode: FileMode.read);
              try {
                var remaining = compressedSize;
                while (remaining > 0) {
                  final chunk = await tempFile.read(xczCopyChunkSize);
                  await output.writeFrom(chunk);
                  remaining -= chunk.length;
                }
              } finally {
                await tempFile.close();
              }

              await partitionBuilder.finalizeFileWrite(nczName);
            } else {
              // Non-NCA or small NCA: copy verbatim
              await partitionBuilder.addFile(fileEntry.name, fileEntry.size);

              var remaining = fileEntry.size;
              var srcOffset = 0;
              const chunkSize = xczCopyChunkSize;
              while (remaining > 0) {
                final take = remaining < chunkSize ? remaining : chunkSize;
                final chunk = await partitionSrcReader.readEntry(
                  fileEntry,
                  offset: srcOffset,
                  length: take,
                );
                await output.writeFrom(chunk);
                remaining -= chunk.length;
                srcOffset += chunk.length;
                processedBytes += chunk.length;
                onProgress?.call(
                  'Copying ${fileEntry.name}',
                  (processedBytes / totalBytes).clamp(0.0, 1.0),
                );
              }

              await partitionBuilder.finalizeFileWrite(fileEntry.name);
            }
          }

          // Finalize the nested HFS0 header (seek-back write)
          await partitionBuilder.end();

          // Python: alignedSize = partitionOut.actualSize + allign0x200(partitionOut.actualSize)
          // allign0x200(n) = 0x200 - n % 0x200  — always adds padding
          final partitionActualSize = partitionBuilder.actualSize;
          final alignPadding = _pythonAlign0x200(partitionActualSize);
          final alignedSize = partitionActualSize + alignPadding;
          if (alignPadding > 0) {
            await output.writeFrom(Uint8List(alignPadding));
          }

          // Register in root builder (offset relative to data region start)
          rootBuilder.entries.add(Hfs0BuilderEntry(
            name: partitionEntry.name,
            size: alignedSize,
            offset: rootAddPos - rootBuilder.headerReservedSize,
          ));
          rootAddPos += alignedSize;
        }

        // Keep rootBuilder.actualSize in sync so end() writes header correctly
        rootBuilder.actualSize = rootAddPos;
      }

      // Finalize root HFS0 header (seek-back write)
      await rootBuilder.end();
      onProgress?.call('Done', 1.0);
    } finally {
      await source.close();
      await output.close();
      await reader.close();
      await _cleanup(tempDir);
    }
  }

  /// Decompresses every NCZ in [inputXczPath] back to NCA and writes a `.xci`
  /// to [outputPath]. No keys required.
  static Future<void> decompress({
    required String inputXczPath,
    required String outputPath,
    String? tempDirPath,
    void Function(String message, double fraction)? onProgress,
  }) async {
    final source = await File(inputXczPath).open(mode: FileMode.read);
    final output = await File(outputPath).open(mode: FileMode.write);
    final tempDir = await _createTempDir('xcz_decompress_', tempDirPath);
    final reader = await XciReader.open(inputXczPath);

    try {
      final hfs0Offset = await _findHfs0Offset(source);

      // 1. Copy XCI header verbatim
      onProgress?.call('Copying XCI header', 0.0);
      await source.setPosition(0);
      var remainingHeader = hfs0Offset;
      while (remainingHeader > 0) {
        final take = remainingHeader < xczCopyChunkSize ? remainingHeader : xczCopyChunkSize;
        final bytes = await source.read(take);
        await output.writeFrom(bytes);
        remainingHeader -= bytes.length;
      }

      // 2. Compute total source bytes for progress
      var totalBytes = 0;
      for (final partitionEntry in reader.rootHfs0.header.entries) {
        final partitionSrcOffset = reader.rootHfs0.dataRegionOffset + partitionEntry.offset;
        final pr = Hfs0Reader(source, partitionSrcOffset);
        await pr.initialize();
        for (final fileEntry in pr.header.entries) {
          totalBytes += fileEntry.size;
        }
      }
      var processedBytes = 0;

      // 3. Root Hfs0Builder
      final rootBuilder = Hfs0Builder(file: output, startOffset: hfs0Offset);
      await rootBuilder.begin();
      var rootAddPos = rootBuilder.headerReservedSize;

      for (final partitionEntry in reader.rootHfs0.header.entries) {
        final partitionSrcOffset = reader.rootHfs0.dataRegionOffset + partitionEntry.offset;
        final partitionSrcReader = Hfs0Reader(source, partitionSrcOffset);
        await partitionSrcReader.initialize();

        final isDummy = partitionSrcReader.header.entries.isEmpty;
        if (isDummy) {
          // Write dummy partition verbatim
          final dummy = ByteData(0x200);
          dummy.setUint8(0, 0x48);
          dummy.setUint8(1, 0x46);
          dummy.setUint8(2, 0x53);
          dummy.setUint8(3, 0x30);
          dummy.setUint32(4, 0, Endian.little);
          dummy.setUint32(8, 1, Endian.little);
          dummy.setUint32(12, 0, Endian.little);
          await output.writeFrom(dummy.buffer.asUint8List());

          rootBuilder.entries.add(Hfs0BuilderEntry(
            name: partitionEntry.name,
            size: 0x200,
            offset: rootAddPos - rootBuilder.headerReservedSize,
          ));
          rootAddPos += 0x200;
        } else {
          final partitionStartInOutput = hfs0Offset + rootAddPos;
          final partitionBuilder = Hfs0Builder(
            file: output,
            startOffset: partitionStartInOutput,
          );
          await partitionBuilder.begin();

          for (final fileEntry in partitionSrcReader.header.entries) {
            final isNcz = Ncz.isNcz(fileEntry.name);

            if (isNcz) {
              final tempPath = p.join(tempDir.path, '${fileEntry.name}.nca');
              final sink = File(tempPath).openWrite();
              final decoder = ZstdDecoder();

              int decompressedSize = 0;
              try {
                decompressedSize = await Ncz.decompress(
                  read: (offset, length) => partitionSrcReader.readEntry(
                    fileEntry,
                    offset: offset,
                    length: length,
                  ),
                  nczSize: fileEntry.size,
                  decoder: decoder,
                  sink: sink,
                  chunkSize: xczCopyChunkSize,
                  onBytes: (delta) {
                    processedBytes += delta;
                    onProgress?.call(
                      'Decompressing ${fileEntry.name}',
                      (processedBytes / totalBytes).clamp(0.0, 1.0),
                    );
                  },
                );
              } finally {
                await sink.flush();
                await sink.close();
                decoder.dispose();
              }

              final ncaName = _swapExtension(fileEntry.name, '.nca');
              await partitionBuilder.addFile(ncaName, decompressedSize);

              final tempFile = await File(tempPath).open(mode: FileMode.read);
              try {
                var remaining = decompressedSize;
                while (remaining > 0) {
                  final chunk = await tempFile.read(xczCopyChunkSize);
                  await output.writeFrom(chunk);
                  remaining -= chunk.length;
                }
              } finally {
                await tempFile.close();
              }

              await partitionBuilder.finalizeFileWrite(ncaName);
            } else {
              await partitionBuilder.addFile(fileEntry.name, fileEntry.size);

              var remaining = fileEntry.size;
              var srcOffset = 0;
              const chunkSize = xczCopyChunkSize;
              while (remaining > 0) {
                final take = remaining < chunkSize ? remaining : chunkSize;
                final chunk = await partitionSrcReader.readEntry(
                  fileEntry,
                  offset: srcOffset,
                  length: take,
                );
                await output.writeFrom(chunk);
                remaining -= chunk.length;
                srcOffset += chunk.length;
                processedBytes += chunk.length;
                onProgress?.call(
                  'Copying ${fileEntry.name}',
                  (processedBytes / totalBytes).clamp(0.0, 1.0),
                );
              }

              await partitionBuilder.finalizeFileWrite(fileEntry.name);
            }
          }

          await partitionBuilder.end();

          final partitionActualSize = partitionBuilder.actualSize;
          final alignPadding = _pythonAlign0x200(partitionActualSize);
          final alignedSize = partitionActualSize + alignPadding;
          if (alignPadding > 0) {
            await output.writeFrom(Uint8List(alignPadding));
          }

          rootBuilder.entries.add(Hfs0BuilderEntry(
            name: partitionEntry.name,
            size: alignedSize,
            offset: rootAddPos - rootBuilder.headerReservedSize,
          ));
          rootAddPos += alignedSize;
        }

        rootBuilder.actualSize = rootAddPos;
      }

      await rootBuilder.end();
      onProgress?.call('Done', 1.0);
    } finally {
      await source.close();
      await output.close();
      await reader.close();
      await _cleanup(tempDir);
    }
  }

  static Future<int> _findHfs0Offset(RandomAccessFile file) async {
    int headOffset = -1;
    final magicBytes100 = await _readExact(file, 0x100, 4);
    final magic100 = ByteData.sublistView(magicBytes100).getUint32(0, Endian.little);
    if (magic100 == 0x44414548) {
      headOffset = 0x100;
    } else {
      final magicBytes1100 = await _readExact(file, 0x1100, 4);
      final magic1100 = ByteData.sublistView(magicBytes1100).getUint32(0, Endian.little);
      if (magic1100 == 0x44414548) headOffset = 0x1100;
    }
    if (headOffset == -1) {
      throw const FormatException('Not a valid XCI container (bad header magic).');
    }
    final offsetBytes = await _readExact(file, headOffset + 0x30, 8);
    return ByteData.sublistView(offsetBytes).getUint64(0, Endian.little);
  }

  static Future<Map<String, SwitchTicket>> _loadTickets(Hfs0Reader partition) async {
    final tickets = <String, SwitchTicket>{};
    for (final entry in partition.header.entries) {
      if (!entry.name.toLowerCase().endsWith('.tik')) continue;
      final bytes = await partition.readEntry(entry);
      try {
        final ticket = SwitchTicket.parse(bytes);
        tickets[_hex(ticket.rightsId)] = ticket;
      } on SwitchKeysException {
        // Skip malformed tickets
      }
    }
    return tickets;
  }

  static String _swapExtension(String name, String newExtension) =>
      '${name.substring(0, name.lastIndexOf('.'))}$newExtension';

  static String _hex(Uint8List bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  static Future<void> _cleanup(Directory dir) async {
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
  }

  static Future<Directory> _createTempDir(String prefix, String? base) async {
    if (base != null) {
      final root = Directory(base);
      await root.create(recursive: true);
      return root.createTemp(prefix);
    }
    return Directory.systemTemp.createTemp(prefix);
  }

  static Future<Uint8List> _readExact(RandomAccessFile file, int offset, int length) async {
    if (length == 0) return Uint8List(0);
    await file.setPosition(offset);
    final out = Uint8List(length);
    var read = 0;
    while (read < length) {
      final chunk = await file.read(length - read);
      if (chunk.isEmpty) {
        throw const FormatException('Unexpected end of file while reading.');
      }
      out.setRange(read, read + chunk.length, chunk);
      read += chunk.length;
    }
    return out;
  }
}
