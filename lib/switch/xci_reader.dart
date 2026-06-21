import 'dart:io';
import 'dart:typed_data';
import 'hfs0.dart';

class XciEntry {
  final String name;
  final int offset; // Absolute offset in XCI file
  final int size;

  XciEntry({
    required this.name,
    required this.offset,
    required this.size,
  });
}

class XciReader {
  final RandomAccessFile _file;
  final List<XciEntry> entries;
  late final Hfs0Reader rootHfs0;
  late final Hfs0Reader secureHfs0;

  XciReader._(this._file, this.entries);

  static Future<XciReader> open(String path) async {
    final file = await File(path).open(mode: FileMode.read);
    try {
      int headOffset = -1;

      // 1. Try checking offset 0x100 (256) for "HEAD" magic
      final magicBytes100 = await _readExact(file, 0x100, 4);
      final magic100 = ByteData.sublistView(magicBytes100).getUint32(0, Endian.little);
      if (magic100 == 0x44414548) { // "HEAD"
        headOffset = 0x100;
      } else {
        // Try offset 0x1100 (4352)
        final magicBytes1100 = await _readExact(file, 0x1100, 4);
        final magic1100 = ByteData.sublistView(magicBytes1100).getUint32(0, Endian.little);
        if (magic1100 == 0x44414548) { // "HEAD"
          headOffset = 0x1100;
        }
      }

      if (headOffset == -1) {
        throw const FormatException('Not a valid XCI container (bad header magic).');
      }

      // 2. Read hfs0_offset at headOffset + 0x30
      final offsetBytes = await _readExact(file, headOffset + 0x30, 8);
      final hfs0Offset = ByteData.sublistView(offsetBytes).getUint64(0, Endian.little);

      // 3. Initialize root Hfs0Reader
      final rootHfs0 = Hfs0Reader(file, hfs0Offset);
      await rootHfs0.initialize();

      // Find secure partition
      Hfs0Entry? secureEntry;
      for (final entry in rootHfs0.header.entries) {
        if (entry.name == 'secure') {
          secureEntry = entry;
          break;
        }
      }

      if (secureEntry == null) {
        throw const FormatException('Secure partition not found in XCI.');
      }

      // 4. Initialize secure Hfs0Reader
      final secureHfs0Offset = rootHfs0.dataRegionOffset + secureEntry.offset;
      final secureHfs0 = Hfs0Reader(file, secureHfs0Offset);
      await secureHfs0.initialize();

      final entries = <XciEntry>[];
      final secureDataRegionOffset = secureHfs0.dataRegionOffset;
      for (final entry in secureHfs0.header.entries) {
        entries.add(XciEntry(
          name: entry.name,
          offset: secureDataRegionOffset + entry.offset,
          size: entry.size,
        ));
      }

      final reader = XciReader._(file, entries);
      reader.rootHfs0 = rootHfs0;
      reader.secureHfs0 = secureHfs0;
      return reader;
    } catch (_) {
      await file.close();
      rethrow;
    }
  }

  Future<void> close() => _file.close();

  static Future<Uint8List> _readExact(RandomAccessFile file, int offset, int length) async {
    if (length == 0) return Uint8List(0);
    await file.setPosition(offset);
    final out = Uint8List(length);
    var read = 0;
    while (read < length) {
      final chunk = await file.read(length - read);
      if (chunk.isEmpty) {
        throw const FormatException('Unexpected end of XCI/HFS0 file.');
      }
      out.setRange(read, read + chunk.length, chunk);
      read += chunk.length;
    }
    return out;
  }
}
