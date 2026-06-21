/// The NCZ codec: compresses a single NCA into the Nicoboss `.ncz` layout and
/// reconstructs the original NCA from a `.ncz`.
///
/// `.ncz` layout:
/// ```
/// [0x0000 .. 0x4000)  the original NCA's first 0x4000 bytes, verbatim
/// "NCZSECTN" (8)      magic
/// sectionCount u64
/// section[sectionCount] (0x40 each):
///     offset u64, size u64, cryptoType u64, padding u64,
///     cryptoKey[16], cryptoCounter[16]
/// <body>
/// ```
///
/// The `<body>` after the section table is the decrypted body bytes
/// `[0x4000 .. ncaSize)` in one of two compression layouts:
///
/// * **solid** — a single zstd stream (what our compressor emits). Detected by
///   the absence of the `NCZBLOCK` magic.
/// * **block** — an `NCZBLOCK` seek table followed by `numberOfBlocks`
///   independent zstd frames (or raw-stored blocks when compression didn't
///   help). The reference `nsz` commonly chooses this layout. We *read* it but
///   never write it. Layout of the block header:
///   ```
///   "NCZBLOCK" (8)        magic
///   version u8, type u8, unused u8, blockSizeExponent u8
///   numberOfBlocks u32
///   decompressedSize u64
///   compressedBlockSize[numberOfBlocks] u32   ← bytes each stored block occupies
///   ```
///   Each block decompresses to `1 << blockSizeExponent` bytes, except the last
///   which is `decompressedSize % blockSize` (when non-zero). A block whose
///   stored size is `< blockSize` is a zstd frame; otherwise it is stored raw.
///
/// The `cryptoKey`/`cryptoCounter` are stored in the clear, so **decompression
/// needs no `prod.keys`** — it re-encrypts each AES-CTR section from the
/// embedded values. Only compression needs keys (to decrypt in the first place).
///
/// FORMAT RISK: `cryptoType` numbering and the exact section partitioning must
/// match the reference `nsz` tool for cross-tool compatibility; validate with a
/// byte-identical round-trip and against a real `nsz`-produced `.ncz`.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:zstd_ffi/zstd_ffi.dart';

import '../io_tuning.dart';
import '../src/aes_ctr.dart';
import 'nca.dart';

const int nczUncompressedHeaderSize = 0x4000;
const List<int> _nczSectionMagic = [0x4E, 0x43, 0x5A, 0x53, 0x45, 0x43, 0x54, 0x4E]; // NCZSECTN
const List<int> _nczBlockMagic = [0x4E, 0x43, 0x5A, 0x42, 0x4C, 0x4F, 0x43, 0x4B]; // NCZBLOCK
const int _nczSectionEntrySize = 0x40;
const int _nczBlockHeaderFixedSize = 0x18; // up to (and excluding) compressedBlockSize list

// cryptoType values written into the NCZSECTN table.
const int _cryptoNone = 1;
const int _cryptoCtr = 3;
const int _cryptoCtrEx = 4;

// I/O chunk size; defined centrally as [nczIoChunkSize].
const int _ioChunk = nczIoChunkSize;

/// Reads [length] bytes at NCA-relative [offset].
typedef NcaRangeReader = Future<Uint8List> Function(int offset, int length);

/// A contiguous slice of the compressed body and how to (de)crypt it.
class _BodySection {
  final int offset; // absolute within the NCA
  final int size;
  final int cryptoType;
  final Uint8List key; // 16 bytes (zeros for none)
  final Uint8List counter; // 16 bytes (zeros for none)

  _BodySection(this.offset, this.size, this.cryptoType, this.key, this.counter);

  bool get isEncrypted => cryptoType == _cryptoCtr || cryptoType == _cryptoCtrEx;
}

class Ncz {
  /// Whether [name] / [firstBytes] look like an already-compressed NCZ.
  static bool isNcz(String name) => name.toLowerCase().endsWith('.ncz');

  /// Partitions [0x4000, ncaSize) into a gap-free list of body sections from the
  /// parsed NCA [sections], filling uncovered ranges with plaintext (NONE).
  ///
  /// For [NcaSectionCrypto.aesCtrEx] (BKTR) sections the BKTR2 subsection
  /// table is fetched via [read] and each subsection entry becomes its own
  /// [_BodySection] with the correct per-entry CTR counter — mirroring
  /// nsz.py's `getEncryptionSections()` / `setBktrCounter()` logic. Without
  /// this, the entire BKTR section would be decrypted with the wrong counter
  /// for all but the first sub-block, producing pseudo-random bytes that zstd
  /// cannot compress.
  static Future<List<_BodySection>> _partition(
    List<NcaSection> sections,
    int ncaSize,
    NcaRangeReader read,
  ) async {
    final sorted = [...sections]..sort((a, b) => a.offset.compareTo(b.offset));
    final result = <_BodySection>[];
    var pointer = nczUncompressedHeaderSize;

    void addNone(int from, int to) {
      if (to > from) {
        result.add(_BodySection(from, to - from, _cryptoNone, Uint8List(16), Uint8List(16)));
      }
    }

    for (final section in sorted) {
      var start = section.offset;
      final end = section.offset + section.size;
      if (end <= nczUncompressedHeaderSize) continue; // wholly inside the header
      if (start < pointer) {
        // Section starts before the current pointer (e.g. partially inside the
        // verbatim header region). Clamp to pointer rather than skipping the
        // whole section — we just skip the already-covered prefix bytes.
        start = pointer;
      }
      if (start >= end) continue; // nothing left after clamping

      addNone(pointer, start);
      final clampedEnd = end > ncaSize ? ncaSize : end;
      final cryptoType = switch (section.crypto) {
        NcaSectionCrypto.none => _cryptoNone,
        NcaSectionCrypto.aesCtr => _cryptoCtr,
        NcaSectionCrypto.aesCtrEx => _cryptoCtrEx,
        NcaSectionCrypto.unsupported => _cryptoNone,
      };

      if (cryptoType == _cryptoCtrEx &&
          section.bktr2Size > 0 &&
          section.bktr2Offset + section.bktr2Size <= section.size) {
        // BKTR section: parse the BKTR2 subsection table and emit one
        // _BodySection per entry with its individual counter.
        final bktr2Sections = await _parseBktr2(
          read: read,
          section: section,
          clampedEnd: clampedEnd,
          pointer: start,
        );
        result.addAll(bktr2Sections);
      } else {
        // Plain CTR or unknown crypto: single entry.
        result.add(_BodySection(
          start,
          clampedEnd - start,
          cryptoType,
          cryptoType == _cryptoNone ? Uint8List(16) : section.bodyKey,
          cryptoType == _cryptoNone ? Uint8List(16) : section.baseCounter,
        ));
      }
      pointer = clampedEnd;
    }
    addNone(pointer, ncaSize);
    return result;
  }

  // ---- BKTR2 table parsing ----

  /// Reads and parses the BKTR2 subsection table for [section] and returns
  /// one [_BodySection] per BKTR2 entry, covering [pointer..clampedEnd).
  ///
  /// BKTR2 body layout (at NCA offset = section.offset + section.bktr2Offset):
  ///
  ///   +0x00  padding          u32
  ///   +0x04  bucketCount      u32   ← number of subsection buckets
  ///   +0x08  patchImageSize   u64
  ///   +0x10  baseOffsets[]    u64 * 2046  (0x3FF0 bytes)
  ///   +0x4000 bucket table   BktrSubsectionBucket[bucketCount]
  ///
  /// Each BktrSubsectionBucket (at offset +0x4000 + cumulative bucket size):
  ///   +0x00  padding          u32
  ///   +0x04  entryCount       u32
  ///   +0x08  endOffset        u64
  ///   +0x10  entries[]        BktrSubsectionEntry[entryCount]
  ///
  /// Each BktrSubsectionEntry (0x10 bytes):
  ///   +0x00  virtualOffset    u64  (relative to section start)
  ///   +0x08  padding          u32
  ///   +0x0C  ctr              u32  (32-bit subsection CTR value)
  ///
  /// The counter for each entry is built with ofs=0 (the AES-CTR block index
  /// starts fresh at the entry boundary), matching nsz.py's:
  ///   `ctr = self.setBktrCounter(entry.ctr, 0)`
  ///
  /// After all BKTR entries, a final tail section is appended using the
  /// section's original [baseCounter], covering from the last entry's end
  /// to [clampedEnd]. This mirrors nsz.py's final `EncryptedSection` append.
  static Future<List<_BodySection>> _parseBktr2({
    required NcaRangeReader read,
    required NcaSection section,
    required int clampedEnd,
    required int pointer,
  }) async {
    // --- Fallback helper ---
    List<_BodySection> fallback() => [
          _BodySection(
            pointer,
            clampedEnd - pointer,
            _cryptoCtrEx,
            section.bodyKey,
            section.baseCounter,
          )
        ];

    final bktr2AbsOffset = section.offset + section.bktr2Offset;

    // Safety: body must be large enough to contain the 0x4000-byte header area
    // plus at least one bucket header.
    if (section.bktr2Size < 0x4010) return fallback();

    // The BKTR2 table in the section body is encrypted; decrypt it first.
    final headBytesEnc = await read(bktr2AbsOffset, 0x08);
    final headCounter = Nca.counterForOffset(section.rawSectionCtr, bktr2AbsOffset);
    final headCipher = AesCtr.fromBigInts(_bigIntFromBytes(section.bodyKey), _bigIntFromBytes(headCounter));
    final headBytes = headCipher.process(headBytesEnc);
    final headView = ByteData.sublistView(headBytes);
    final bucketCount = headView.getUint32(0x04, Endian.little);

    if (bucketCount == 0 || bucketCount > 0xFFFF) return fallback();

    // Bucket table starts at bktr2AbsOffset + 0x4000.
    final bucketTableAbsOffset = bktr2AbsOffset + 0x4000;
    final bucketTableSize = section.bktr2Size - 0x4000;
    if (bucketTableSize <= 0 || bucketTableSize > 64 * 1024 * 1024) {
      return fallback();
    }

    final bucketBytesEnc = await read(bucketTableAbsOffset, bucketTableSize);
    final bucketCounter = Nca.counterForOffset(section.rawSectionCtr, bucketTableAbsOffset);
    final bucketCipher = AesCtr.fromBigInts(_bigIntFromBytes(section.bodyKey), _bigIntFromBytes(bucketCounter));
    final bucketBytes = bucketCipher.process(bucketBytesEnc);
    final bv = ByteData.sublistView(bucketBytes);

    // Collect all subsection entries across all buckets.
    final allEntries = <({int virtualOffset, int size, int ctr})>[];
    int pos = 0;
    for (var b = 0; b < bucketCount; b++) {
      if (pos + 0x10 > bucketTableSize) break;
      // padding u32 at pos+0x00 — skip
      final entryCount = bv.getUint32(pos + 0x04, Endian.little);
      final endOffset  = bv.getUint64(pos + 0x08, Endian.little);
      pos += 0x10;

      if (entryCount == 0 || entryCount > 0xFFFF) {
        pos += entryCount * 0x10;
        continue;
      }

      final bucketEntries = <({int virtualOffset, int ctr})>[];
      for (var e = 0; e < entryCount; e++) {
        if (pos + 0x10 > bucketTableSize) break;
        final virtualOffset = bv.getUint64(pos + 0x00, Endian.little);
        // padding u32 at pos+0x08 — skip
        final ctr = bv.getUint32(pos + 0x0C, Endian.little);
        pos += 0x10;
        bucketEntries.add((virtualOffset: virtualOffset, ctr: ctr));
      }

      // Compute entry sizes: span to next entry's virtualOffset, or to endOffset.
      for (var i = 0; i < bucketEntries.length; i++) {
        final entryEnd = i + 1 < bucketEntries.length
            ? bucketEntries[i + 1].virtualOffset
            : endOffset;
        allEntries.add((
          virtualOffset: bucketEntries[i].virtualOffset,
          size: entryEnd - bucketEntries[i].virtualOffset,
          ctr: bucketEntries[i].ctr,
        ));
      }
    }

    if (allEntries.isEmpty) return fallback();

    // Build _BodySection list from entries, clipped to [pointer, clampedEnd).
    // Mirror of nsz.py getEncryptionSections():
    //   sections += [EncryptedSection(sectionOffset + e.virtualOffset, e.size,
    //                                 cryptoType, key, setBktrCounter(e.ctr, 0))]
    //   sections += [EncryptedSection(lastEnd, sectionEnd - lastEnd, cryptoType,
    //                                 key, sectionCounter)]  ← tail
    final result = <_BodySection>[];
    for (final e in allEntries) {
      final absStart = section.offset + e.virtualOffset;
      final absEnd   = absStart + e.size;
      if (absEnd <= pointer || absStart >= clampedEnd) continue;
      final cs = absStart < pointer ? pointer : absStart;
      final ce = absEnd   > clampedEnd ? clampedEnd : absEnd;
      if (ce <= cs) continue;

      // Counter: ofs=0 per entry — the AES-CTR block index resets at each
      // BKTR subsection boundary, matching setBktrCounter(entry.ctr, 0).
      final counter = section.bktrCounterForEntry(e.ctr, 0);
      result.add(_BodySection(cs, ce - cs, _cryptoCtrEx, section.bodyKey, counter));
    }

    // Tail section: from last BKTR entry end to section end, encrypted with
    // the section's original baseCounter (matches the reference final append).
    if (allEntries.isNotEmpty) {
      final lastEntry  = allEntries.last;
      final tailAbsStart = section.offset + lastEntry.virtualOffset + lastEntry.size;
      final tailAbsEnd   = clampedEnd;
      if (tailAbsEnd > tailAbsStart && tailAbsStart >= pointer) {
        result.add(_BodySection(
          tailAbsStart,
          tailAbsEnd - tailAbsStart,
          _cryptoCtrEx,
          section.bodyKey,
          section.baseCounter,
        ));
      }
    }

    if (result.isEmpty) return fallback();
    return result;
  }

  /// Compresses an NCA into a `.ncz`.
  ///
  /// [read] returns NCA bytes by relative offset, [ncaSize] is the NCA length,
  /// [nca] is the parsed header, and [encoder]/[sink] are the (caller-owned)
  /// zstd encoder and output. The caller disposes the encoder. [onBytes] is
  /// invoked with the number of NCA body bytes read so far, for progress.
  static Future<void> compress({
    required NcaRangeReader read,
    required int ncaSize,
    required Nca nca,
    required ZstdEncoder encoder,
    required IOSink sink,
    void Function(int bytesRead)? onBytes,
    int chunkSize = _ioChunk,
  }) async {
    // 1. Verbatim header.
    await _copyRange(read, 0, nczUncompressedHeaderSize, sink);

    // 2. NCZSECTN table.
    final body = await _partition(nca.sections, ncaSize, read);
    sink.add(Uint8List.fromList(_nczSectionMagic));
    final countBytes = ByteData(8)..setUint64(0, body.length, Endian.little);
    sink.add(countBytes.buffer.asUint8List());
    for (final section in body) {
      final entry = ByteData(_nczSectionEntrySize);
      entry.setUint64(0x00, section.offset, Endian.little);
      entry.setUint64(0x08, section.size, Endian.little);
      entry.setUint64(0x10, section.cryptoType, Endian.little);
      entry.setUint64(0x18, 0, Endian.little);
      final out = entry.buffer.asUint8List();
      out.setRange(0x20, 0x30, section.key);
      out.setRange(0x30, 0x40, section.counter);
      sink.add(out);
    }

    // 3. Decrypt the body section by section and feed the plaintext to zstd.
    for (final section in body) {
      // Seed the cipher so the AES-CTR block index aligns with the section's
      // absolute NCA offset, exactly like the reference's `crypto.seek(offset)`.
      // The whole section is read contiguously from `section.offset`, so a
      // single seek at the start keeps the index aligned for every chunk.
      final cipher = section.isEncrypted
          ? AesCtr.fromBigInts(
              _bigIntFromBytes(section.key),
              _bigIntFromBytes(_counterAtOffset(section.counter, section.offset)))
          : null;
      var remaining = section.size;
      var position = section.offset;
      while (remaining > 0) {
        final take = remaining < chunkSize ? remaining : chunkSize;
        final encrypted = await read(position, take);
        final plain = cipher == null ? encrypted : cipher.process(encrypted);
        final compressed = encoder.process(plain);
        if (compressed.isNotEmpty) sink.add(compressed);
        position += take;
        remaining -= take;
        onBytes?.call(take);
        await Future.delayed(Duration.zero);
      }
    }
    final tail = encoder.finish();
    if (tail.isNotEmpty) sink.add(tail);
  }

  /// Reconstructs the original NCA from a `.ncz`.
  ///
  /// [read] returns `.ncz` bytes by relative offset, [nczSize] is the `.ncz`
  /// length, and [decoder]/[sink] are the (caller-owned) zstd decoder and
  /// output. No keys are required. Returns the rebuilt NCA size.
  static Future<int> decompress({
    required NcaRangeReader read,
    required int nczSize,
    required ZstdDecoder decoder,
    required IOSink sink,
    void Function(int bytesRead)? onBytes,
    int chunkSize = _ioChunk,
  }) async {
    // 1. Verbatim header.
    await _copyRange(read, 0, nczUncompressedHeaderSize, sink);

    // 2. NCZSECTN table.
    final magic = await read(nczUncompressedHeaderSize, 8);
    if (!_matchesMagic(magic, _nczSectionMagic)) {
      throw const FormatException('Missing NCZSECTN magic (not an NCZ?).');
    }
    final countBytes = await read(nczUncompressedHeaderSize + 8, 8);
    final sectionCount =
        ByteData.sublistView(countBytes).getUint64(0, Endian.little);
    final tableOffset = nczUncompressedHeaderSize + 16;
    final tableBytes = await read(tableOffset, sectionCount * _nczSectionEntrySize);
    final body = _readSectionTable(tableBytes, sectionCount);

    // 3. Decompress the rest, re-encrypting each section as we go. The body is
    // either a single solid zstd stream or an NCZBLOCK seek table + per-block
    // frames; the section/crypto layer (`_BodyEmitter`) is identical for both.
    final streamStart = tableOffset + sectionCount * _nczSectionEntrySize;
    final emitter = _BodyEmitter(body, sink);

    final hasBlockHeader = nczSize - streamStart >= _nczBlockMagic.length &&
        _matchesMagic(await read(streamStart, _nczBlockMagic.length), _nczBlockMagic);
    if (hasBlockHeader) {
      await _decompressBlocks(
        read: read,
        headerOffset: streamStart,
        decoder: decoder,
        emitter: emitter,
        onBytes: onBytes,
      );
    } else {
      var position = streamStart;
      while (position < nczSize) {
        final take = (nczSize - position) < chunkSize ? (nczSize - position) : chunkSize;
        final compressed = await read(position, take);
        final plain = decoder.process(compressed);
        emitter.consume(plain);
        position += take;
        onBytes?.call(take);
        await Future.delayed(Duration.zero);
      }
    }
    return emitter.totalWritten;
  }

  /// Decompresses an `NCZBLOCK` body: parses the seek table at [headerOffset]
  /// and feeds each block's plaintext to [emitter] in order. Mirrors the
  /// reference `BlockDecompressorReader` — a block whose stored size is smaller
  /// than its decompressed size is an independent zstd frame; an equal-or-larger
  /// stored size means the block was kept raw (incompressible).
  ///
  /// The shared streaming [decoder] is reused across frames: each block is a
  /// complete, self-contained zstd frame, so after `process` drains one frame
  /// the decoder sits at a frame boundary ready for the next. Raw blocks bypass
  /// it entirely, leaving that boundary undisturbed.
  static Future<void> _decompressBlocks({
    required NcaRangeReader read,
    required int headerOffset,
    required ZstdDecoder decoder,
    required _BodyEmitter emitter,
    void Function(int bytesRead)? onBytes,
  }) async {
    final fixed = await read(headerOffset, _nczBlockHeaderFixedSize);
    final fixedView = ByteData.sublistView(fixed);
    final blockSizeExponent = fixed[0x0B];
    if (blockSizeExponent < 14 || blockSizeExponent > 32) {
      throw FormatException(
          'Corrupted NCZBLOCK header: block size exponent $blockSizeExponent '
          'out of range [14, 32].');
    }
    final blockCount = fixedView.getUint32(0x0C, Endian.little);
    final decompressedSize = fixedView.getUint64(0x10, Endian.little);
    final blockSize = 1 << blockSizeExponent;

    // Per-block stored sizes, immediately after the fixed header.
    final listBytes =
        await read(headerOffset + _nczBlockHeaderFixedSize, blockCount * 4);
    final listView = ByteData.sublistView(listBytes);
    final storedSizes = List<int>.generate(
        blockCount, (i) => listView.getUint32(i * 4, Endian.little));

    var blockOffset = headerOffset + _nczBlockHeaderFixedSize + blockCount * 4;
    for (var blockId = 0; blockId < blockCount; blockId++) {
      final storedSize = storedSizes[blockId];
      // All blocks decompress to blockSize except the last, which holds the
      // remainder when decompressedSize isn't an exact multiple.
      var decompressedBlockSize = blockSize;
      if (blockId == blockCount - 1) {
        final remainder = decompressedSize % blockSize;
        if (remainder > 0) decompressedBlockSize = remainder;
      }
      final blockBytes = await read(blockOffset, storedSize);
      blockOffset += storedSize;
      final plain = storedSize < decompressedBlockSize
          ? decoder.process(blockBytes)
          : blockBytes;
      emitter.consume(plain);
      onBytes?.call(storedSize);
      await Future.delayed(Duration.zero);
    }
  }

  /// Whether the first [magic].length bytes of [bytes] equal [magic].
  static bool _matchesMagic(List<int> bytes, List<int> magic) {
    if (bytes.length < magic.length) return false;
    for (var i = 0; i < magic.length; i++) {
      if (bytes[i] != magic[i]) return false;
    }
    return true;
  }

  static List<_BodySection> _readSectionTable(Uint8List bytes, int count) {
    final view = ByteData.sublistView(bytes);
    final sections = <_BodySection>[];
    for (var i = 0; i < count; i++) {
      final base = i * _nczSectionEntrySize;
      sections.add(_BodySection(
        view.getUint64(base + 0x00, Endian.little),
        view.getUint64(base + 0x08, Endian.little),
        view.getUint64(base + 0x10, Endian.little),
        Uint8List.sublistView(bytes, base + 0x20, base + 0x30),
        Uint8List.sublistView(bytes, base + 0x30, base + 0x40),
      ));
    }
    return sections;
  }
}

/// Re-encrypts the decompressed plaintext stream section by section, writing
/// the rebuilt NCA body to [sink]. Maintains a running CTR cipher per section
/// so a plaintext chunk that straddles a section boundary is split correctly.
class _BodyEmitter {
  final List<_BodySection> _sections;
  final IOSink _sink;
  int _sectionIndex = 0;
  int _sectionRemaining;
  AesCtr? _cipher;
  int totalWritten = nczUncompressedHeaderSize;

  _BodyEmitter(List<_BodySection> sections, this._sink)
      : _sections = _prepareForDecompress(sections),
        _sectionRemaining = 0 {
    _sectionRemaining = _sections.isEmpty ? 0 : _sections.first.size;
    _initCipherForCurrent();
  }

  /// Reconciles the NCZSECTN table with the zstd stream, which always covers
  /// `[0x4000, ncaSize)`. The reference omits leading plaintext from the table
  /// and lets the first section overlap the verbatim header, so we rebuild that
  /// shape here. Files produced by our own compressor already start the body at
  /// exactly 0x4000 (an explicit leading NONE), so for them this is a no-op.
  ///
  /// Mirrors `NszDecompressor.__decompressNcz` lines 143-145 and 191-195.
  static List<_BodySection> _prepareForDecompress(List<_BodySection> sections) {
    if (sections.isEmpty) return sections;
    final first = sections.first;
    if (first.offset > nczUncompressedHeaderSize) {
      // Plaintext gap between the header and the first section was not stored in
      // the table; rebuild it as a leading NONE section (the reference's
      // FakeSection) so the stream maps onto the right offsets.
      return [
        _BodySection(
          nczUncompressedHeaderSize,
          first.offset - nczUncompressedHeaderSize,
          _cryptoNone,
          Uint8List(16),
          Uint8List(16),
        ),
        ...sections,
      ];
    }
    if (first.offset < nczUncompressedHeaderSize) {
      // The first section overlaps the verbatim header. Its prefix bytes (those
      // below 0x4000) are already in the header, so drop them from the stream
      // and re-base the section to the header boundary. The cipher will then be
      // seeded at absolute 0x4000 via the rewritten offset.
      final overlap = nczUncompressedHeaderSize - first.offset;
      if (first.size <= overlap) {
        // Section lies wholly inside the header; nothing of it is in the stream.
        return sections.skip(1).toList();
      }
      return [
        _BodySection(
          nczUncompressedHeaderSize,
          first.size - overlap,
          first.cryptoType,
          first.key,
          first.counter,
        ),
        ...sections.skip(1),
      ];
    }
    return sections;
  }

  void _initCipherForCurrent() {
    if (_sectionIndex >= _sections.length) {
      _cipher = null;
      return;
    }
    final section = _sections[_sectionIndex];
    // Re-encrypt with the block index derived from the absolute offset, mirroring
    // the reference's `crypto.seek(section.offset)`. This both produces files the
    // reference can read and lets us read reference files (whose stored low bytes
    // are zero — the offset is the source of truth for the block index).
    _cipher = section.isEncrypted
        ? AesCtr.fromBigInts(
            _bigIntFromBytes(section.key),
            _bigIntFromBytes(_counterAtOffset(section.counter, section.offset)))
        : null;
  }

  void consume(Uint8List plain) {
    var offset = 0;
    while (offset < plain.length) {
      if (_sectionIndex >= _sections.length) {
        // More plaintext than the sections account for: write it raw.
        final rest = Uint8List.sublistView(plain, offset);
        _sink.add(rest);
        totalWritten += rest.length;
        return;
      }
      if (_sectionRemaining == 0) {
        _sectionIndex++;
        if (_sectionIndex < _sections.length) {
          _sectionRemaining = _sections[_sectionIndex].size;
        }
        _initCipherForCurrent();
        continue;
      }
      final available = plain.length - offset;
      final take = available < _sectionRemaining ? available : _sectionRemaining;
      final slice = Uint8List.sublistView(plain, offset, offset + take);
      final outBytes = _cipher == null ? slice : _cipher!.process(slice);
      _sink.add(outBytes);
      totalWritten += take;
      offset += take;
      _sectionRemaining -= take;
    }
  }
}

Future<void> _copyRange(
  NcaRangeReader read,
  int offset,
  int length,
  IOSink sink,
) async {
  var remaining = length;
  var position = offset;
  while (remaining > 0) {
    final take = remaining < _ioChunk ? remaining : _ioChunk;
    final bytes = await read(position, take);
    sink.add(bytes);
    position += take;
    remaining -= take;
  }
}

BigInt _bigIntFromBytes(Uint8List bytes) {
  var result = BigInt.zero;
  for (final byte in bytes) {
    result = (result << 8) | BigInt.from(byte);
  }
  return result;
}

/// Returns the 16-byte AES-CTR counter for the start of an NCA section.
///
/// The reference `nsz` treats only `cryptoCounter[0:8]` as the nonce and
/// recomputes the 64-bit block index from the **absolute** NCA offset
/// (`AESCTR(nonce).seek(absoluteOffset)`). It ignores the stored low 8 bytes
/// entirely. We mirror that here: keep the stored high 8 bytes as the nonce and
/// overwrite the low 8 with `absoluteOffset >> 4` (big-endian). This is the one
/// place where the block index must align with the absolute offset rather than
/// the per-section stored counter — see [Ncz] for the cross-tool compatibility
/// rationale (BKTR subsections and sub-0x4000 sections).
Uint8List _counterAtOffset(Uint8List storedCounter, int absoluteOffset) {
  final counter = Uint8List(16);
  counter.setRange(0, 8, storedCounter); // nonce (already correct per section)
  var block = absoluteOffset >> 4;
  for (var byteIndex = 0; byteIndex < 8; byteIndex++) {
    counter[15 - byteIndex] = block & 0xFF;
    block >>= 8;
  }
  return counter;
}
