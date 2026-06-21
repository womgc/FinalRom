import 'dart:io';
import 'dart:typed_data';

class Hfs0Entry {
  final String name;
  final int offset; // Offset relative to the start of the data region
  final int size;
  final int nameOffset; // Offset inside the string table
  final Uint8List hash; // SHA256 of the hashed region (usually 32 bytes of 0s)

  Hfs0Entry({
    required this.name,
    required this.offset,
    required this.size,
    required this.nameOffset,
    required this.hash,
  });
}

class Hfs0Header {
  final List<Hfs0Entry> entries;
  final int headerSize;

  Hfs0Header({required this.entries, required this.headerSize});

  static Hfs0Header parse(Uint8List headerBytes) {
    final view = ByteData.sublistView(headerBytes);
    final magic = view.getUint32(0, Endian.little);
    if (magic != 0x30534648) { // "HFS0"
      throw const FormatException('Invalid HFS0 magic.');
    }
    final fileCount = view.getUint32(4, Endian.little);
    final stringTableSize = view.getUint32(8, Endian.little);

    final entryTableSize = fileCount * 64;
    final stringTableOffset = 16 + entryTableSize;

    if (headerBytes.length < stringTableOffset + stringTableSize) {
      throw const FormatException('HFS0 header buffer is too small for string table.');
    }

    final stringBytes = headerBytes.sublist(
        stringTableOffset, stringTableOffset + stringTableSize);
    final entries = <Hfs0Entry>[];

    for (var i = 0; i < fileCount; i++) {
      final base = 16 + i * 64;
      final offset = view.getUint64(base + 0, Endian.little);
      final size = view.getUint64(base + 8, Endian.little);
      final nameOffset = view.getUint32(base + 16, Endian.little);
      final hash = headerBytes.sublist(base + 32, base + 64);
      final name = _readCString(stringBytes, nameOffset);
      entries.add(Hfs0Entry(
        name: name,
        offset: offset,
        size: size,
        nameOffset: nameOffset,
        hash: hash,
      ));
    }

    return Hfs0Header(
      entries: entries,
      headerSize: 16 + entryTableSize + stringTableSize,
    );
  }

  static String _readCString(Uint8List table, int offset) {
    var end = offset;
    while (end < table.length && table[end] != 0) {
      end++;
    }
    return String.fromCharCodes(table.sublist(offset, end));
  }
}

class Hfs0Reader {
  final RandomAccessFile file;
  final int startOffset;
  late final Hfs0Header header;

  Hfs0Reader(this.file, this.startOffset);

  Future<void> initialize() async {
    await file.setPosition(startOffset);
    final headerBase = await _readExact(file, 16);
    final view = ByteData.sublistView(headerBase);
    final magic = view.getUint32(0, Endian.little);
    if (magic != 0x30534648) {
      throw const FormatException('Invalid HFS0 magic.');
    }
    final fileCount = view.getUint32(4, Endian.little);
    final stringTableSize = view.getUint32(8, Endian.little);

    final remainingSize = fileCount * 64 + stringTableSize;
    final remainingBytes = await _readExact(file, remainingSize);

    final allBytes = Uint8List(16 + remainingBytes.length);
    allBytes.setRange(0, 16, headerBase);
    allBytes.setRange(16, allBytes.length, remainingBytes);

    header = Hfs0Header.parse(allBytes);
  }

  int get dataRegionOffset => startOffset + header.headerSize;

  Future<Uint8List> readEntry(Hfs0Entry entry, {int offset = 0, int? length}) async {
    final readLen = length ?? (entry.size - offset);
    await file.setPosition(dataRegionOffset + entry.offset + offset);
    return _readExact(file, readLen);
  }

  static Future<Uint8List> _readExact(RandomAccessFile file, int length) async {
    if (length == 0) return Uint8List(0);
    final out = Uint8List(length);
    var read = 0;
    while (read < length) {
      final chunk = await file.read(length - read);
      if (chunk.isEmpty) {
        throw const FormatException('Unexpected end of file in Hfs0Reader.');
      }
      out.setRange(read, read + chunk.length, chunk);
      read += chunk.length;
    }
    return out;
  }
}

class Hfs0BuilderEntry {
  final String name;
  int size;
  int offset; // Relative to data region start (headerReservedSize)

  Hfs0BuilderEntry({
    required this.name,
    required this.size,
    required this.offset,
  });
}

class Hfs0Builder {
  final RandomAccessFile file;
  final int startOffset;
  final int headerReservedSize;
  final List<Hfs0BuilderEntry> entries = [];
  int actualSize = 0; // Relative to startOffset

  Hfs0Builder({
    required this.file,
    required this.startOffset,
    this.headerReservedSize = 0x8000,
  });

  Future<void> begin() async {
    await file.setPosition(startOffset + headerReservedSize);
    actualSize = headerReservedSize;
  }

  Future<int> addFile(String name, int initialSize) async {
    final relativeOffset = actualSize - headerReservedSize;
    final entry = Hfs0BuilderEntry(
      name: name,
      size: initialSize,
      offset: relativeOffset,
    );
    entries.add(entry);

    final absoluteOffset = startOffset + actualSize;
    await file.setPosition(absoluteOffset);
    return absoluteOffset;
  }

  void resizeFile(String name, int newSize) {
    for (final entry in entries) {
      if (entry.name == name) {
        entry.size = newSize;
        break;
      }
    }
  }

  Future<void> finalizeFileWrite(String name) async {
    final pos = await file.position();
    final relativePos = pos - startOffset;
    if (relativePos > actualSize) {
      actualSize = relativePos;
    }
  }

  Future<void> end() async {
    final stringTable = BytesBuilder();
    final nameOffsets = <int>[];
    for (final entry in entries) {
      nameOffsets.add(stringTable.length);
      stringTable.add(Uint8List.fromList(entry.name.codeUnits));
      stringTable.addByte(0);
    }

    final entryTableSize = entries.length * 64;
    final headerSize = 16 + entryTableSize + stringTable.length;
    if (headerSize > headerReservedSize) {
      throw FormatException(
          'HFS0 Header size ($headerSize) exceeds reserved size ($headerReservedSize).');
    }

    final header = ByteData(16);
    // Magic "HFS0"
    header.setUint8(0, 0x48);
    header.setUint8(1, 0x46);
    header.setUint8(2, 0x53);
    header.setUint8(3, 0x30);
    header.setUint32(4, entries.length, Endian.little);
    header.setUint32(8, stringTable.length, Endian.little);
    header.setUint32(12, 0, Endian.little);

    final entryTable = ByteData(entryTableSize);
    for (var i = 0; i < entries.length; i++) {
      final entry = entries[i];
      final base = i * 64;
      // Adjust offset to be relative to the end of the actual header structure
      final relativeToHeaderEnd = entry.offset + (headerReservedSize - headerSize);

      entryTable.setUint64(base + 0, relativeToHeaderEnd, Endian.little);
      entryTable.setUint64(base + 8, entry.size, Endian.little);
      entryTable.setUint32(base + 16, nameOffsets[i], Endian.little);
      entryTable.setUint32(base + 20, 0, Endian.little);
      entryTable.setUint64(base + 24, 0, Endian.little);
      // Bytes 32-64 are sha256 (zero-padded)
      for (var j = 0; j < 32; j++) {
        entryTable.setUint8(base + 32 + j, 0);
      }
    }

    final builder = BytesBuilder();
    builder.add(header.buffer.asUint8List());
    builder.add(entryTable.buffer.asUint8List());
    builder.add(stringTable.toBytes());

    await file.setPosition(startOffset);
    await file.writeFrom(builder.toBytes());

    // Seek to the end of the HFS0 partition data
    await file.setPosition(startOffset + actualSize);
  }
}
