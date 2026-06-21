import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// AES-128-XTS as used by Switch NCA headers.
///
/// NCA headers are encrypted with the 32-byte `header_key` split into a data
/// key (first 16 bytes) and a tweak key (last 16 bytes), over 0x200-byte
/// sectors starting at sector 0. Nintendo encodes the per-sector tweak as a
/// **big-endian** 128-bit sector index (the non-standard quirk vs. the
/// little-endian convention in the XTS spec); the GF(2^128) tweak update is
/// mirrored to match.
///
/// NOTE: the big-endian tweak detail is the highest-risk part of NCA parsing —
/// validate decrypted headers begin with the `NCA0`/`NCA2`/`NCA3` magic before
/// trusting the section table (see [Nca]).
class AesXts {
  final BlockCipher _dataCipher;
  final BlockCipher _tweakCipher;
  final int sectorSize;

  AesXts._(this._dataCipher, this._tweakCipher, this.sectorSize);

  /// Builds an XTS context from the 32-byte [headerKey] (dataKey ‖ tweakKey).
  factory AesXts(Uint8List headerKey, {int sectorSize = 0x200}) {
    if (headerKey.length != 32) {
      throw ArgumentError('XTS header key must be 32 bytes.');
    }
    final dataKey = Uint8List.sublistView(headerKey, 0, 16);
    final tweakKey = Uint8List.sublistView(headerKey, 16, 32);
    final dataCipher = AESEngine()..init(false, KeyParameter(dataKey));
    final tweakCipher = AESEngine()..init(true, KeyParameter(tweakKey));
    return AesXts._(dataCipher, tweakCipher, sectorSize);
  }

  /// Decrypts [data] (a whole number of sectors) starting at [startSector].
  Uint8List decrypt(Uint8List data, {int startSector = 0}) {
    if (data.length % sectorSize != 0) {
      throw ArgumentError('XTS input must be a multiple of the sector size.');
    }
    final output = Uint8List(data.length);
    var sector = startSector;
    for (var base = 0; base < data.length; base += sectorSize) {
      _decryptSector(data, output, base, sector);
      sector++;
    }
    return output;
  }

  void _decryptSector(Uint8List src, Uint8List dst, int base, int sector) {
    final tweak = _initialTweak(sector);
    for (var blockOffset = 0; blockOffset < sectorSize; blockOffset += 16) {
      final start = base + blockOffset;
      final block = Uint8List(16);
      for (var i = 0; i < 16; i++) {
        block[i] = src[start + i] ^ tweak[i];
      }
      final decrypted = Uint8List(16);
      _dataCipher.processBlock(block, 0, decrypted, 0);
      for (var i = 0; i < 16; i++) {
        dst[start + i] = decrypted[i] ^ tweak[i];
      }
      _advanceTweak(tweak);
    }
  }

  Uint8List _initialTweak(int sector) {
    // Big-endian 128-bit sector index, then encrypted with the tweak key.
    final tweak = Uint8List(16);
    var value = sector;
    for (var i = 15; i >= 0; i--) {
      tweak[i] = value & 0xFF;
      value >>= 8;
    }
    final encrypted = Uint8List(16);
    _tweakCipher.processBlock(tweak, 0, encrypted, 0);
    return encrypted;
  }

  /// GF(2^128) multiply-by-x for the per-block tweak update. Nintendo's only
  /// deviation from standard XTS is encoding the *sector number* big-endian (see
  /// [_initialTweak]); the block-to-block tweak multiply is the **standard**
  /// little-endian one (byte 0 is least significant), matching hactool. Shift
  /// the 128-bit value left by one bit and fold the carry into byte 0 with the
  /// 0x87 reduction polynomial.
  void _advanceTweak(Uint8List tweak) {
    var carry = 0;
    for (var i = 0; i < 16; i++) {
      final next = (tweak[i] >> 7) & 1;
      tweak[i] = ((tweak[i] << 1) | carry) & 0xFF;
      carry = next;
    }
    if (carry != 0) {
      tweak[0] ^= 0x87;
    }
  }
}
