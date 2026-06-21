/// Parser for the Switch `.cnmt` (ContentMeta) binary format. Operates on the
/// already-decrypted bytes of a meta NCA's single section — no file I/O here.
///
/// Layout (switchbrew/hactool convention):
/// ```
/// ContentMetaHeader (0x20 bytes):
///   0x00 titleId u64 LE
///   0x08 version u32 LE
///   0x0C type u8
///   0x0D reserved u8
///   0x0E extendedHeaderSize u16 LE
///   0x10 contentCount u16 LE
///   0x12 contentMetaCount u16 LE
///   0x14 attributes u8
///   0x15 reserved[3]
///   0x18 requiredDownloadSystemVersion u32 LE
///   0x1C reserved[4]
/// extended header (extendedHeaderSize bytes, type-specific, not interpreted)
/// PackagedContentInfo[contentCount] (0x38 bytes each — a 0x20-byte SHA-256
/// hash of the NCA followed by the 0x18-byte NcmContentInfo struct):
///   +0x00 hash (32 bytes, not used here)
///   +0x20 ncaId (16 bytes, raw)
///   +0x30 size (48-bit LE)
///   +0x36 contentType u8
///   +0x37 idOffset u8
/// ```
library;

import 'dart:typed_data';

enum ContentMetaType {
  systemProgram,
  systemData,
  systemUpdate,
  bootImagePackage,
  bootImagePackageSafe,
  application,
  patch,
  addOnContent,
  delta,
  dataPatch,
  unknown,
}

enum ContentEntryType {
  meta,
  program,
  data,
  control,
  htmlDocument,
  legalInformation,
  deltaFragment,
  unknown,
}

class ContentEntry {
  final String ncaIdHex;
  final int size;
  final ContentEntryType type;

  const ContentEntry({
    required this.ncaIdHex,
    required this.size,
    required this.type,
  });
}

class ContentMeta {
  static const int headerSize = 0x20;
  static const int contentInfoSize = 0x38;

  final int titleId;
  final int version;
  final ContentMetaType metaType;
  final List<ContentEntry> contentEntries;

  const ContentMeta._({
    required this.titleId,
    required this.version,
    required this.metaType,
    required this.contentEntries,
  });

  factory ContentMeta.parse(Uint8List bytes) {
    if (bytes.length < headerSize) {
      throw const FormatException('CNMT body shorter than its fixed header.');
    }
    final view = ByteData.sublistView(bytes);
    final titleId = view.getUint64(0x00, Endian.little);
    final version = view.getUint32(0x08, Endian.little);
    final metaType = _metaTypeFrom(bytes[0x0C]);
    final extendedHeaderSize = view.getUint16(0x0E, Endian.little);
    final contentCount = view.getUint16(0x10, Endian.little);

    final tableStart = headerSize + extendedHeaderSize;
    final tableEnd = tableStart + contentCount * contentInfoSize;
    if (bytes.length < tableEnd) {
      throw const FormatException('CNMT content table runs past the buffer.');
    }

    final entries = <ContentEntry>[];
    for (var i = 0; i < contentCount; i++) {
      final base = tableStart + i * contentInfoSize;
      final ncaId = Uint8List.sublistView(bytes, base + 0x20, base + 0x30);
      final sizeLow = view.getUint32(base + 0x30, Endian.little);
      final sizeHigh = view.getUint16(base + 0x34, Endian.little);
      final size = sizeLow | (sizeHigh << 32);
      final contentType = _entryTypeFrom(bytes[base + 0x36]);
      entries.add(ContentEntry(
        ncaIdHex: _hex(ncaId),
        size: size,
        type: contentType,
      ));
    }

    return ContentMeta._(
      titleId: titleId,
      version: version,
      metaType: metaType,
      contentEntries: entries,
    );
  }

  static String _hex(Uint8List bytes) {
    final builder = StringBuffer();
    for (final byte in bytes) {
      builder.write(byte.toRadixString(16).padLeft(2, '0'));
    }
    return builder.toString();
  }

  static ContentMetaType _metaTypeFrom(int value) {
    switch (value) {
      case 1:
        return ContentMetaType.systemProgram;
      case 2:
        return ContentMetaType.systemData;
      case 3:
        return ContentMetaType.systemUpdate;
      case 4:
        return ContentMetaType.bootImagePackage;
      case 5:
        return ContentMetaType.bootImagePackageSafe;
      case 0x80:
        return ContentMetaType.application;
      case 0x81:
        return ContentMetaType.patch;
      case 0x82:
        return ContentMetaType.addOnContent;
      case 0x83:
        return ContentMetaType.delta;
      case 0x84:
        return ContentMetaType.dataPatch;
      default:
        return ContentMetaType.unknown;
    }
  }

  static ContentEntryType _entryTypeFrom(int value) {
    switch (value) {
      case 0:
        return ContentEntryType.meta;
      case 1:
        return ContentEntryType.program;
      case 2:
        return ContentEntryType.data;
      case 3:
        return ContentEntryType.control;
      case 4:
        return ContentEntryType.htmlDocument;
      case 5:
        return ContentEntryType.legalInformation;
      case 6:
        return ContentEntryType.deltaFragment;
      default:
        return ContentEntryType.unknown;
    }
  }
}
