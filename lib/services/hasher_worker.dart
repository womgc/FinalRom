import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:final_rom/io_tuning.dart';

class HasherParams {
  final String filePath;
  final SendPort sendPort;

  HasherParams({required this.filePath, required this.sendPort});
}

class HasherResult {
  final bool success;
  final String? error;
  final String? md5Hash;
  final String? sha1Hash;
  final String? sha256Hash;
  final String? crc32Hash;

  HasherResult({
    required this.success,
    this.error,
    this.md5Hash,
    this.sha1Hash,
    this.sha256Hash,
    this.crc32Hash,
  });
}

/// CRC32 (IEEE 802.3) lookup table, built once per isolate instead of on every
/// hash call.
final List<int> _crc32Table = _makeCrcTable();

class HasherWorker {
  /// Reading in large blocks (rather than the ~64 KB chunks `File.openRead`
  /// yields) cuts per-chunk overhead and lets each hash process bigger slices,
  /// which is the dominant cost when hashing on mobile. See [hashReadBufferSize].
  static const int _readBufferSize = hashReadBufferSize;

  static Future<void> runHasher(HasherParams params) async {
    RandomAccessFile? file;
    try {
      file = await File(params.filePath).open(mode: FileMode.read);

      final md5Output = AccumulatorSink<Digest>();
      final sha1Output = AccumulatorSink<Digest>();
      final sha256Output = AccumulatorSink<Digest>();

      final md5Input = md5.startChunkedConversion(md5Output);
      final sha1Input = sha1.startChunkedConversion(sha1Output);
      final sha256Input = sha256.startChunkedConversion(sha256Output);

      var crc32Value = 0xFFFFFFFF;
      final buffer = Uint8List(_readBufferSize);

      while (true) {
        final read = await file.readInto(buffer);
        if (read <= 0) break;

        // Each hash consumes the slice synchronously inside add(), so reusing
        // the buffer for the next read is safe.
        final chunk =
            read == buffer.length ? buffer : Uint8List.sublistView(buffer, 0, read);
        md5Input.add(chunk);
        sha1Input.add(chunk);
        sha256Input.add(chunk);

        for (var i = 0; i < read; i++) {
          crc32Value =
              _crc32Table[(crc32Value ^ buffer[i]) & 0xFF] ^ (crc32Value >>> 8);
        }
      }

      md5Input.close();
      sha1Input.close();
      sha256Input.close();

      crc32Value ^= 0xFFFFFFFF;
      final crc32Hash = crc32Value.toRadixString(16).padLeft(8, '0').toUpperCase();

      params.sendPort.send(HasherResult(
        success: true,
        md5Hash: md5Output.events.single.toString(),
        sha1Hash: sha1Output.events.single.toString(),
        sha256Hash: sha256Output.events.single.toString(),
        crc32Hash: crc32Hash,
      ));
    } catch (e) {
      params.sendPort.send(HasherResult(success: false, error: e.toString()));
    } finally {
      await file?.close();
    }
  }
}

List<int> _makeCrcTable() {
  final table = List<int>.filled(256, 0);
  for (var i = 0; i < 256; i++) {
    var c = i;
    for (var j = 0; j < 8; j++) {
      if ((c & 1) != 0) {
        c = 0xEDB88320 ^ (c >>> 1);
      } else {
        c = c >>> 1;
      }
    }
    table[i] = c;
  }
  return table;
}

class AccumulatorSink<T> implements Sink<T> {
  final List<T> events = [];
  bool isClosed = false;

  @override
  void add(T event) {
    events.add(event);
  }

  @override
  void close() {
    isClosed = true;
  }
}
