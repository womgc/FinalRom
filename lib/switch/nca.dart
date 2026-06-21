import 'dart:typed_data';

import '../src/aes_ctr.dart';
import '../src/big_int_ops.dart';
import 'aes_xts.dart';
import 'keys.dart';

/// NCA content kinds (header byte 0x205).
enum NcaContentType { program, meta, control, manual, data, publicData, unknown }

/// The crypto applied to a section's body bytes (FS-header byte 0x04).
enum NcaSectionCrypto { none, aesCtr, aesCtrEx, unsupported }

/// One decrypted NCA section: where its bytes live in the file and how to
/// decrypt them. [bodyKey] / [baseCounter] are the values an NSZ `.ncz` records
/// in its `NCZSECTN` table so decompression can re-encrypt without keys.
class NcaSection {
  final int offset; // absolute, within the NCA
  final int size;
  final NcaSectionCrypto crypto;
  final Uint8List bodyKey; // 16 bytes (empty for [NcaSectionCrypto.none])
  final Uint8List baseCounter; // 16 bytes, the CTR nonce at [offset]

  /// The raw 8-byte section counter from FS-header bytes 0x140..0x148.
  /// Used by the NCZ compressor to build per-subsection counters for
  /// [NcaSectionCrypto.aesCtrEx] (BKTR) sections via [bktrCounterForEntry].
  final Uint8List rawSectionCtr; // 8 bytes (zeros for non-CTR sections)

  /// For [NcaSectionCrypto.aesCtrEx] sections, the byte offset of the BKTR2
  /// (subsection) table **relative to the start of this section** within the
  /// NCA body. Zero for all other section types.
  final int bktr2Offset;

  /// For [NcaSectionCrypto.aesCtrEx] sections, the byte size of the BKTR2
  /// subsection table. Zero for all other section types.
  final int bktr2Size;

  /// For sections hashed with `HierarchicalSha256` (PartitionFs sections —
  /// ExeFS/Logo/Meta/Control NCAs), the byte offset of the inner PFS0
  /// **relative to the start of this section's decrypted body**. The section
  /// body is not the raw PFS0 itself: it's a master hash followed by the
  /// PFS0 partition. Zero (with [pfs0Size] also zero) for sections hashed
  /// with `HierarchicalIntegrity` (RomFS sections), which this app never
  /// needs to unwrap.
  final int pfs0Offset;

  /// Byte size of the inner PFS0 at [pfs0Offset]. Zero when not applicable.
  final int pfs0Size;

  NcaSection({
    required this.offset,
    required this.size,
    required this.crypto,
    required this.bodyKey,
    required this.baseCounter,
    Uint8List? rawSectionCtr,
    this.bktr2Offset = 0,
    this.bktr2Size = 0,
    this.pfs0Offset = 0,
    this.pfs0Size = 0,
  }) : rawSectionCtr = rawSectionCtr ?? Uint8List(8);

  /// Builds an [AesCtr] cipher positioned at the start of this section.
  AesCtr cipherAtStart() => AesCtr.fromBigInts(
        bigIntFromBytesBE(bodyKey),
        bigIntFromBytesBE(baseCounter),
      );

  /// Builds the 16-byte AES-CTR counter for a BKTR subsection entry.
  ///
  /// Mirrors nsz.py's `setBktrCounter(ctr_val, virtualOffset)`:
  ///   bytes [0..3]  = high 4 bytes of [rawSectionCtr] (the section nonce)
  ///   bytes [4..7]  = [entryCtr] (32-bit subsection CTR), big-endian
  ///   bytes [8..15] = [entryVirtualOffset] >> 4 (block index), big-endian
  Uint8List bktrCounterForEntry(int entryCtr, int entryVirtualOffset) {
    final ctr = Uint8List(16);
    // High 4 bytes: take rawSectionCtr[7..4] reversed (the section nonce high
    // bytes). rawSectionCtr is stored as the 8 bytes at FS-header 0x140..0x148
    // in their original (little-endian nonce) order, so bytes [7..4] hold the
    // "upper" part of the nonce after the byte-reversal done in counterForOffset.
    for (var i = 0; i < 4; i++) {
      ctr[i] = rawSectionCtr[7 - i];
    }
    // Bytes [4..7]: subsection CTR value, big-endian.
    var cv = entryCtr;
    for (var j = 0; j < 4; j++) {
      ctr[7 - j] = cv & 0xFF;
      cv >>= 8;
    }
    // Bytes [8..15]: virtual block index (virtualOffset >> 4), big-endian.
    var block = entryVirtualOffset >> 4;
    for (var j = 0; j < 8; j++) {
      ctr[15 - j] = block & 0xFF;
      block >>= 8;
    }
    return ctr;
  }
}

/// Parses the (XTS-decrypted) NCA header and exposes its sections.
///
/// HIGH-RISK PARSING: NCA header field offsets, the master-key generation
/// fixup, the key-area index, and the AES-CTR nonce construction all follow
/// hactool. Validate against a real NCA (header magic must be `NCA3`/`NCA2`,
/// and an NSZ round-trip must reproduce byte-identical NCAs) before relying on
/// it — this is the correctness gate called out in the plan.
class Nca {
  static const int headerEncryptedRegion = 0xC00; // signatures + header + FS headers
  static const int fsHeaderBase = 0x400;
  static const int fsHeaderSize = 0x200;
  static const int sectionTableBase = 0x240;
  static const int keyAreaBase = 0x300;

  final Uint8List decryptedHeader; // first 0xC00 bytes, XTS-decrypted
  final NcaContentType contentType;
  final List<NcaSection> sections;

  /// 16-byte rights ID (FS header 0x230..0x240). All-zero when this NCA does
  /// not use titlekey crypto.
  final Uint8List rightsId;

  Nca._(this.decryptedHeader, this.contentType, this.sections, this.rightsId);

  /// Whether the decrypted header starts with an NCA magic this parser actually
  /// supports. Only `NCA3`/`NCA2` share the header/key-area layout used below;
  /// `NCA0`/`NCA1` differ and would be silently mis-parsed by a 3-byte prefix
  /// check, so the full 4-byte magic is compared.
  static bool hasValidMagic(Uint8List decryptedHeader) {
    final magic = String.fromCharCodes(decryptedHeader.sublist(0x200, 0x204));
    return magic == 'NCA3' || magic == 'NCA2';
  }

  /// Parses an NCA from its raw (still XTS-encrypted) first [headerEncryptedRegion]
  /// bytes [rawHeader], using [keys]. When the NCA uses titlekey crypto,
  /// [resolveTicket] is called with the NCA's rights id to find the matching
  /// ticket.
  factory Nca.parse(
    Uint8List rawHeader,
    SwitchKeys keys, {
    SwitchTicket? Function(Uint8List rightsId)? resolveTicket,
  }) {
    final xts = AesXts(keys.headerKey);
    final header = xts.decrypt(
      Uint8List.sublistView(rawHeader, 0, headerEncryptedRegion),
    );
    if (!hasValidMagic(header)) {
      throw const FormatException(
          'NCA header did not decrypt to a valid magic (wrong header_key?).');
    }

    final view = ByteData.sublistView(header);
    final contentType = _contentTypeFrom(header[0x205]);
    final keyIndex = header[0x207];
    final generation = _generationFrom(header[0x206], header[0x220]);

    final rightsId = Uint8List.sublistView(header, 0x230, 0x240);
    final usesTitleKey = rightsId.any((byte) => byte != 0);

    final bodyKeyCtr = usesTitleKey
        ? _titleKeyOrThrow(resolveTicket?.call(rightsId), keys)
        : SwitchKeys.aesEcbDecrypt(
            keys.keyAreaKek(keyIndex, generation),
            Uint8List.sublistView(header, keyAreaBase + 0x20, keyAreaBase + 0x30),
          );

    final sections = <NcaSection>[];
    for (var i = 0; i < 4; i++) {
      final entryBase = sectionTableBase + i * 0x10;
      final startBlock = view.getUint32(entryBase + 0x00, Endian.little);
      final endBlock = view.getUint32(entryBase + 0x04, Endian.little);
      if (endBlock <= startBlock) continue; // empty / unused section

      final offset = startBlock * 0x200;
      final size = (endBlock - startBlock) * 0x200;

      final fsHeaderOffset = fsHeaderBase + i * fsHeaderSize;
      final hashType = header[fsHeaderOffset + 0x02];
      final encryptionType = header[fsHeaderOffset + 0x04];
      final crypto = _cryptoFrom(encryptionType);

      final sectionCtr =
          Uint8List.sublistView(header, fsHeaderOffset + 0x140, fsHeaderOffset + 0x148);

      // For aesCtrEx (BKTR) sections, read the BKTR2 (subsection) table
      // location from the FS header. The 16-byte descriptor at offset 0x120
      // contains: [0x00] bktr2_offset u64 LE, [0x08] bktr2_size u64 LE.
      // Both are relative to the start of the section body (i.e. [offset]).
      int bktr2Offset = 0;
      int bktr2Size = 0;
      if (crypto == NcaSectionCrypto.aesCtrEx) {
        final bktr2Base = fsHeaderOffset + 0x120;
        bktr2Offset = view.getUint64(bktr2Base + 0x00, Endian.little);
        bktr2Size = view.getUint64(bktr2Base + 0x08, Endian.little);
      }

      // hashType == 1 means this section's hash superblock is
      // HierarchicalSha256 (PartitionFs sections: ExeFS/Logo/Meta/Control) —
      // a master hash followed by the actual PFS0 partition. pfs0_offset and
      // pfs0_size live in that superblock at fsHeaderOffset+0x40/+0x48, both
      // relative to the start of the section's decrypted body. hashType == 2
      // (HierarchicalIntegrity / RomFS) has no such offset and is left at 0.
      int pfs0Offset = 0;
      int pfs0Size = 0;
      if (hashType == 1) {
        pfs0Offset = view.getUint64(fsHeaderOffset + 0x40, Endian.little);
        pfs0Size = view.getUint64(fsHeaderOffset + 0x48, Endian.little);
      }

      sections.add(NcaSection(
        offset: offset,
        size: size,
        crypto: crypto,
        pfs0Offset: pfs0Offset,
        pfs0Size: pfs0Size,
        bodyKey: crypto == NcaSectionCrypto.none ? Uint8List(0) : bodyKeyCtr,
        baseCounter: crypto == NcaSectionCrypto.none
            ? Uint8List(16)
            : counterForOffset(sectionCtr, offset),
        rawSectionCtr:
            (crypto == NcaSectionCrypto.aesCtr || crypto == NcaSectionCrypto.aesCtrEx)
                ? Uint8List.fromList(sectionCtr)
                : null,
        bktr2Offset: bktr2Offset,
        bktr2Size: bktr2Size,
      ));
    }

    return Nca._(header, contentType, sections, rightsId);
  }

  /// Builds the 16-byte AES-CTR nonce for absolute [offset] from the section's
  /// 8-byte [sectionCtr] (FS header 0x140): high 8 bytes are the section CTR in
  /// reverse byte order, low 8 bytes are the 0x10-block index, big-endian.
  static Uint8List counterForOffset(Uint8List sectionCtr, int offset) {
    final counter = Uint8List(16);
    for (var i = 0; i < 8; i++) {
      counter[i] = sectionCtr[7 - i];
    }
    var block = offset >> 4;
    for (var i = 0; i < 8; i++) {
      counter[15 - i] = block & 0xFF;
      block >>= 8;
    }
    return counter;
  }

  static Uint8List _titleKeyOrThrow(SwitchTicket? ticket, SwitchKeys keys) {
    if (ticket == null) {
      throw const FormatException(
          'NCA uses titlekey crypto but no ticket was provided.');
    }
    return ticket.decryptTitleKey(keys);
  }

  static int _generationFrom(int oldField, int newField) {
    var generation = oldField > newField ? oldField : newField;
    if (generation > 0) generation -= 1; // generations 0 and 1 both map to 0
    return generation;
  }

  static NcaContentType _contentTypeFrom(int value) {
    switch (value) {
      case 0:
        return NcaContentType.program;
      case 1:
        return NcaContentType.meta;
      case 2:
        return NcaContentType.control;
      case 3:
        return NcaContentType.manual;
      case 4:
        return NcaContentType.data;
      case 5:
        return NcaContentType.publicData;
      default:
        return NcaContentType.unknown;
    }
  }

  static NcaSectionCrypto _cryptoFrom(int encryptionType) {
    switch (encryptionType) {
      case 1:
        return NcaSectionCrypto.none;
      case 2:
      case 3:
        return NcaSectionCrypto.aesCtr;
      case 4:
        return NcaSectionCrypto.aesCtrEx;
      default:
        return NcaSectionCrypto.unsupported;
    }
  }
}
