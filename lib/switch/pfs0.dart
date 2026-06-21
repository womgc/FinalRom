/// Reader/writer for the `PFS0` partition-filesystem container used by Switch
/// `.nsp` / `.nsz` files. A PFS0 is a flat list of named members (NCAs, the
/// ticket, the cert, the `.cnmt` files) laid out as:
///
/// ```
/// magic "PFS0" (4)  | fileCount u32 | stringTableSize u32 | reserved u32
/// entries[fileCount] (0x18 each): dataOffset u64, dataSize u64,
///                                 nameOffset u32, reserved u32
/// string table (stringTableSize, null-terminated names)
/// data region (member bytes; dataOffset is relative to the start of this region)
/// ```
library;

import 'dart:io';
import 'dart:typed_data';

import '../io_tuning.dart';

const List<int> _pfs0Magic = [0x50, 0x46, 0x53, 0x30]; // "PFS0"
const int _headerBaseSize = 0x10;
const int _entrySize = 0x18;

/// A single member of a PFS0 container, with absolute offsets into the file.
class Pfs0Entry {
  final String name;

  /// Absolute byte offset of the member's data within the PFS0 file.
  final int dataOffset;
  final int dataSize;

  const Pfs0Entry({
    required this.name,
    required this.dataOffset,
    required this.dataSize,
  });
}

/// Parses a PFS0 container that already lives fully in memory (e.g. the
/// inner partition unwrapped from a Meta/Control NCA's hashed section, as
/// opposed to a `.nsp` file on disk). Returns each entry's bytes directly
/// rather than a file offset.
List<Uint8List> parsePfs0Bytes(Uint8List bytes) {
  if (bytes.length < _headerBaseSize) {
    throw const FormatException('PFS0 buffer shorter than its fixed header.');
  }
  for (var i = 0; i < _pfs0Magic.length; i++) {
    if (bytes[i] != _pfs0Magic[i]) {
      throw const FormatException('Not a PFS0 container (bad magic).');
    }
  }
  final view = ByteData.sublistView(bytes);
  final fileCount = view.getUint32(0x04, Endian.little);
  final stringTableSize = view.getUint32(0x08, Endian.little);

  final entryTableSize = fileCount * _entrySize;
  final stringTableOffset = _headerBaseSize + entryTableSize;
  final dataRegionOffset = stringTableOffset + stringTableSize;
  if (dataRegionOffset > bytes.length) {
    throw const FormatException('PFS0 header/table runs past the buffer.');
  }

  final out = <Uint8List>[];
  for (var i = 0; i < fileCount; i++) {
    final base = _headerBaseSize + i * _entrySize;
    final relativeOffset = view.getUint64(base + 0x00, Endian.little);
    final size = view.getUint64(base + 0x08, Endian.little);
    final dataOffset = dataRegionOffset + relativeOffset;
    // `relativeOffset`/`size` come from untrusted u64 fields; a value >= 2^63
    // reads back as a negative Dart int, so guard the low end as well.
    if (relativeOffset < 0 ||
        size < 0 ||
        dataOffset + size > bytes.length) {
      throw FormatException(
          'PFS0 entry $i data range [$dataOffset, ${dataOffset + size}) '
          'is outside the ${bytes.length}-byte buffer.');
    }
    out.add(Uint8List.sublistView(bytes, dataOffset, dataOffset + size));
  }
  return out;
}

/// Parsed view of a PFS0 container backed by a file on disk. Open with
/// [Pfs0Reader.open]; remember to [close] when done.
class Pfs0Reader {
  final RandomAccessFile _file;
  final List<Pfs0Entry> entries;

  Pfs0Reader._(this._file, this.entries);

  static Future<Pfs0Reader> open(String path) async {
    final file = await File(path).open(mode: FileMode.read);
    try {
      final header = await _readExact(file, 0, _headerBaseSize);
      for (var i = 0; i < _pfs0Magic.length; i++) {
        if (header[i] != _pfs0Magic[i]) {
          throw const FormatException('Not a PFS0 container (bad magic).');
        }
      }
      final view = ByteData.sublistView(header);
      final fileCount = view.getUint32(0x04, Endian.little);
      final stringTableSize = view.getUint32(0x08, Endian.little);

      final entryTableSize = fileCount * _entrySize;
      final entryBytes =
          await _readExact(file, _headerBaseSize, entryTableSize);
      final stringTableOffset = _headerBaseSize + entryTableSize;
      final stringBytes =
          await _readExact(file, stringTableOffset, stringTableSize);
      final dataRegionOffset = stringTableOffset + stringTableSize;

      final entries = <Pfs0Entry>[];
      final entryView = ByteData.sublistView(entryBytes);
      for (var i = 0; i < fileCount; i++) {
        final base = i * _entrySize;
        final relativeOffset = entryView.getUint64(base + 0x00, Endian.little);
        final size = entryView.getUint64(base + 0x08, Endian.little);
        final nameOffset = entryView.getUint32(base + 0x10, Endian.little);
        entries.add(Pfs0Entry(
          name: _readCString(stringBytes, nameOffset),
          dataOffset: dataRegionOffset + relativeOffset,
          dataSize: size,
        ));
      }
      return Pfs0Reader._(file, entries);
    } catch (_) {
      await file.close();
      rethrow;
    }
  }

  /// Reads up to [length] bytes from member [entry] starting at [offsetInEntry].
  Future<Uint8List> readEntry(
    Pfs0Entry entry, {
    int offsetInEntry = 0,
    int? length,
  }) async {
    final readLength = length ?? (entry.dataSize - offsetInEntry);
    return _readExact(_file, entry.dataOffset + offsetInEntry, readLength);
  }

  /// Copies the full bytes of member [entry] to [sink] in [chunkSize] chunks.
  Future<void> copyEntryTo(
    Pfs0Entry entry,
    IOSink sink, {
    int chunkSize = pfs0EntryCopyChunkSize,
  }) async {
    var remaining = entry.dataSize;
    var position = entry.dataOffset;
    while (remaining > 0) {
      final take = remaining < chunkSize ? remaining : chunkSize;
      final bytes = await _readExact(_file, position, take);
      sink.add(bytes);
      position += take;
      remaining -= take;
    }
  }

  Future<void> close() => _file.close();
}

/// A member to write into a [Pfs0Builder]: either an in-memory blob or a slice
/// of an existing file (so multi-GB NCAs are streamed, never buffered whole).
class Pfs0Member {
  final String name;
  final int size;
  final Uint8List? bytes;
  final String? sourcePath;
  final int sourceOffset;

  Pfs0Member.fromBytes(this.name, Uint8List data)
      : bytes = data,
        size = data.length,
        sourcePath = null,
        sourceOffset = 0;

  Pfs0Member.fromFile(
    this.name,
    this.sourcePath, {
    required this.size,
    this.sourceOffset = 0,
  }) : bytes = null;
}

/// Writes a PFS0 container to disk from a set of [Pfs0Member]s, streaming file
/// members chunk by chunk.
class Pfs0Builder {
  final List<Pfs0Member> _members = [];

  void add(Pfs0Member member) => _members.add(member);

  /// Writes the container to [outputPath]. [onProgress] (if given) is called as
  /// member bytes are written with the running byte count and the total payload
  /// size, so callers can show progress during the (often multi-GB) data copy.
  ///
  /// [chunkSize] controls the read/write buffer size; see [pfs0AssemblyChunkSize].
  Future<void> writeTo(
    String outputPath, {
    int chunkSize = pfs0AssemblyChunkSize,
    void Function(int bytesWritten, int totalBytes)? onProgress,
  }) async {
    final stringTable = BytesBuilder();
    final nameOffsets = <int>[];
    for (final member in _members) {
      nameOffsets.add(stringTable.length);
      stringTable.add(Uint8List.fromList(member.name.codeUnits));
      stringTable.addByte(0);
    }
    // Pad the string table to align the data region to 0x20 bytes.
    // Mirror Python's allign0x20(n) = 0x20 - n%0x20, which always adds padding
    // even when already aligned (same pattern as HFS0's allign0x200).
    final unpaddedHeader =
        _headerBaseSize + _members.length * _entrySize + stringTable.length;
    final alignPadding = 0x20 - (unpaddedHeader % 0x20); // always 1..0x20
    final stringTableSize = stringTable.length + alignPadding;

    final header = BytesBuilder();
    final fixed = ByteData(_headerBaseSize);
    for (var i = 0; i < _pfs0Magic.length; i++) {
      fixed.setUint8(i, _pfs0Magic[i]);
    }
    fixed.setUint32(0x04, _members.length, Endian.little);
    fixed.setUint32(0x08, stringTableSize, Endian.little);
    fixed.setUint32(0x0C, 0, Endian.little);
    header.add(fixed.buffer.asUint8List());

    var runningOffset = 0;
    for (var i = 0; i < _members.length; i++) {
      final member = _members[i];
      final entry = ByteData(_entrySize);
      entry.setUint64(0x00, runningOffset, Endian.little);
      entry.setUint64(0x08, member.size, Endian.little);
      entry.setUint32(0x10, nameOffsets[i], Endian.little);
      entry.setUint32(0x14, 0, Endian.little);
      header.add(entry.buffer.asUint8List());
      runningOffset += member.size;
    }

    header.add(stringTable.toBytes());
    final padding = stringTableSize - stringTable.length;
    if (padding > 0) header.add(Uint8List(padding));

    final totalBytes =
        _members.fold<int>(0, (sum, member) => sum + member.size);
    var bytesWritten = 0;
    void report(int delta) {
      bytesWritten += delta;
      onProgress?.call(bytesWritten, totalBytes);
    }

    // Use RandomAccessFile directly — WriteFile syscalls map 1:1 to OS write
    // cache with no Dart-level queue overhead (unlike IOSink which adds a
    // stream layer that hurts throughput on large sequential writes).
    final sink = await File(outputPath).open(mode: FileMode.write);
    try {
      await sink.writeFrom(header.toBytes());

      // Keep one open handle per source file across all its members so the OS
      // read-ahead buffer stays warm (avoids per-NCA open/seek/close cost).
      final openHandles = <String, RandomAccessFile>{};
      try {
        for (final member in _members) {
          if (member.bytes != null) {
            await sink.writeFrom(member.bytes!);
            report(member.bytes!.length);
          } else {
            final path = member.sourcePath!;
            var handle = openHandles[path];
            if (handle == null) {
              handle = await File(path).open(mode: FileMode.read);
              openHandles[path] = handle;
            }
            await _streamFromHandle(
              handle,
              member.sourceOffset,
              member.size,
              sink,
              chunkSize,
              report,
            );
          }
        }
      } finally {
        for (final h in openHandles.values) {
          await h.close();
        }
      }
    } finally {
      await sink.close();
    }
  }
}

/// Streams [size] bytes from [handle] starting at [offset] into [sink].
///
/// Reusing an already-open handle across members avoids repeated open/close
/// syscalls and keeps the OS sequential read-ahead buffer warm.
///
/// Note: deliberately uses `read()` (a fresh buffer per chunk) rather than
/// `readInto()` into a reused buffer. Benchmarking on real NSPs
/// (tool/bench_pfs0_assembly.dart) showed `read()` is ~40% faster for the read
/// itself — Dart's native `read()` path beats `readInto`, and the GC absorbs
/// the large short-lived allocations cheaply. See plan notes.
Future<void> _streamFromHandle(
  RandomAccessFile handle,
  int offset,
  int size,
  RandomAccessFile sink,
  int chunkSize,
  void Function(int delta) report,
) async {
  await handle.setPosition(offset);
  var remaining = size;
  while (remaining > 0) {
    final take = remaining < chunkSize ? remaining : chunkSize;
    final bytes = await handle.read(take);
    if (bytes.isEmpty) {
      throw const FormatException('Unexpected end of source file.');
    }
    await sink.writeFrom(bytes);
    remaining -= bytes.length;
    report(bytes.length);
  }
}

Future<Uint8List> _readExact(RandomAccessFile file, int offset, int length) async {
  if (length == 0) return Uint8List(0);
  await file.setPosition(offset);
  final out = Uint8List(length);
  var read = 0;
  while (read < length) {
    final chunk = await file.read(length - read);
    if (chunk.isEmpty) {
      throw const FormatException('Unexpected end of PFS0 file.');
    }
    out.setRange(read, read + chunk.length, chunk);
    read += chunk.length;
  }
  return out;
}

String _readCString(Uint8List table, int offset) {
  var end = offset;
  while (end < table.length && table[end] != 0) {
    end++;
  }
  return String.fromCharCodes(table.sublist(offset, end));
}
