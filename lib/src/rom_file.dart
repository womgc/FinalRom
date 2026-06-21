import 'dart:io';
import 'dart:typed_data';

import 'big_int_ops.dart';

/// Random-access wrapper around a ROM file.
///
/// Replaces the two Python file handles (`f` opened `rb`, `g` opened `rb+`)
/// with a single handle. Every read and write seeks explicitly first, so the
/// open position is irrelevant and reads/writes never interfere — this is the
/// correct, single-view equivalent of the original two-handle approach.
///
/// Opened with [FileMode.append], which on every platform gives read+write
/// access *without truncating* the file (Dart opens it `O_RDWR` and merely
/// seeks to the end initially; [setPositionSync] overrides that).
class RomFile {
  final RandomAccessFile _raf;

  RomFile._(this._raf);

  static Future<RomFile> open(String path) async {
    final raf = await File(path).open(mode: FileMode.append);
    return RomFile._(raf);
  }

  /// Total file length in bytes.
  int get lengthSync => _raf.lengthSync();

  /// Read [length] bytes starting at absolute [position].
  Uint8List readAt(int position, int length) {
    _raf.setPositionSync(position);
    return _raf.readSync(length);
  }

  /// Write [bytes] starting at absolute [position].
  void writeAt(int position, List<int> bytes) {
    _raf.setPositionSync(position);
    _raf.writeFromSync(bytes);
  }

  /// Read an unsigned little-endian 32-bit integer (`struct '<L'`).
  int readUint32LE(int position) =>
      ByteData.view(readAt(position, 4).buffer).getUint32(0, Endian.little);

  /// Read eight unsigned bytes (`struct '<BBBBBBBB'`).
  Uint8List readBytes(int position, int length) => readAt(position, length);

  /// Read an 8-byte little-endian value as a [BigInt] (`struct '<Q'`), avoiding
  /// signed-int overflow for TitleIDs at or above 2^63.
  BigInt readUint64LEAsBigInt(int position) {
    final bytes = readAt(position, 8);
    var result = BigInt.zero;
    for (var i = 7; i >= 0; i--) {
      result = (result << 8) | BigInt.from(bytes[i]);
    }
    return result;
  }

  /// Read a 16-byte big-endian value as a [BigInt] (`struct '>QQ'`).
  BigInt readUint128BE(int position) => bigIntFromBytesBE(readAt(position, 16));

  /// Shrink the file to [length] bytes, dropping everything past it (used to
  /// strip the trailing cartridge padding when writing a trimmed ROM).
  void truncate(int length) => _raf.truncateSync(length);

  Future<void> flush() => _raf.flush();

  Future<void> close() => _raf.close();
}
