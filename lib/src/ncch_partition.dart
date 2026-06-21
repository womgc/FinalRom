import 'dart:typed_data';

import 'big_int_ops.dart';
import 'keys.dart';
import 'rom_file.dart';

/// Parsed fields of one NCCH partition, shared by the decrypt and encrypt
/// ports. All offsets/lengths are in NCSD media units (sectors); multiply by
/// the NCSD `sectorsize` to get byte offsets.
///
/// Field positions mirror the `f.seek(...)` offsets in the Python scripts.
class PartitionInfo {
  /// Partition start, in sectors (NCSD partition table entry).
  final int partOffSectors;

  /// Partition length, in sectors.
  final int partLenSectors;

  /// Byte offset of the partition start (`partOffSectors * sectorsize`).
  final int partBase;

  /// NCCH flags, 8 bytes at +0x188. Index 3 = crypto method (key select),
  /// index 7 = bit flags (0x01 FixedCryptoKey, 0x04 NoCrypto, 0x20 NewKeyY).
  final Uint8List ncchFlags;

  /// KeyY: first 16 bytes of the partition signature, read big-endian.
  final BigInt keyY;

  /// TitleID, read little-endian.
  final BigInt titleId;

  /// CTR initial counters (TitleID joined with the region counter constant).
  final BigInt plainIV;
  final BigInt exefsIV;
  final BigInt romfsIV;

  /// Extended header length in bytes.
  final int exhdrLen;

  /// Plain region offset/length (sectors).
  final int plainOff;
  final int plainLen;

  /// Logo region offset/length (sectors).
  final int logoOff;
  final int logoLen;

  /// ExeFS offset/length (sectors).
  final int exefsOff;
  final int exefsLen;

  /// RomFS offset/length (sectors).
  final int romfsOff;
  final int romfsLen;

  const PartitionInfo({
    required this.partOffSectors,
    required this.partLenSectors,
    required this.partBase,
    required this.ncchFlags,
    required this.keyY,
    required this.titleId,
    required this.plainIV,
    required this.exefsIV,
    required this.romfsIV,
    required this.exhdrLen,
    required this.plainOff,
    required this.plainLen,
    required this.logoOff,
    required this.logoLen,
    required this.exefsOff,
    required this.exefsLen,
    required this.romfsOff,
    required this.romfsLen,
  });

  /// The NormalKey derived from KeyX 0x2C and this partition's KeyY
  /// (`NormalKey2C` in the scripts).
  BigInt normalKey2C(ThreeDsKeys keys) => keys.deriveNormalKey(keys.keyX0x2C, keyY);

  /// Read and parse the NCCH header fields of the partition starting at
  /// [partOffSectors]. Assumes the partition exists and the `NCCH` magic has
  /// already been verified by the caller.
  static PartitionInfo read(
    RomFile rom,
    int partOffSectors,
    int partLenSectors,
    int sectorsize,
  ) {
    final base = partOffSectors * sectorsize;
    final titleId = rom.readUint64LEAsBigInt(base + 0x108);
    return PartitionInfo(
      partOffSectors: partOffSectors,
      partLenSectors: partLenSectors,
      partBase: base,
      ncchFlags: rom.readBytes(base + 0x188, 8),
      keyY: rom.readUint128BE(base + 0x0),
      titleId: titleId,
      plainIV: ((titleId << 64) | plainCounter) & mask128,
      exefsIV: ((titleId << 64) | exefsCounter) & mask128,
      romfsIV: ((titleId << 64) | romfsCounter) & mask128,
      exhdrLen: rom.readUint32LE(base + 0x180),
      plainOff: rom.readUint32LE(base + 0x190),
      plainLen: rom.readUint32LE(base + 0x194),
      logoOff: rom.readUint32LE(base + 0x198),
      logoLen: rom.readUint32LE(base + 0x19C),
      exefsOff: rom.readUint32LE(base + 0x1A0),
      exefsLen: rom.readUint32LE(base + 0x1A4),
      romfsOff: rom.readUint32LE(base + 0x1B0),
      romfsLen: rom.readUint32LE(base + 0x1B4),
    );
  }
}



/// Human-readable name for a crypto method, for progress messages.
String cryptoMethodName(int cryptoMethod) {
  switch (cryptoMethod) {
    case 0x00:
      return 'Key 0x2C';
    case 0x01:
      return 'Key 0x25';
    case 0x0A:
      return 'Key 0x18';
    case 0x0B:
      return 'Key 0x1B';
    default:
      return 'Key 0x2C';
  }
}
