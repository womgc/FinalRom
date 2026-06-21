import 'big_int_ops.dart';

/// 3DS NCCH crypto keys and the key-scrambling routine.
///
/// Direct port of the key/constant block shared by `b3DSDecrypt.py` and
/// `b3DSEncrypt.py`.
class ThreeDsKeys {
  final BigInt generator;
  final BigInt keyX0x18;
  final BigInt keyX0x1B;
  final BigInt keyX0x25;
  final BigInt keyX0x2C;

  const ThreeDsKeys({
    required this.generator,
    required this.keyX0x18,
    required this.keyX0x1B,
    required this.keyX0x25,
    required this.keyX0x2C,
  });

  /// Parse the keys from 3dskeys.txt contents.
  /// Standard format: `keyName=hexValue`
  factory ThreeDsKeys.parse(String text) {
    BigInt? generator;
    BigInt? keyX0x18;
    BigInt? keyX0x1B;
    BigInt? keyX0x25;
    BigInt? keyX0x2C;

    final lines = text.split(RegExp(r'\r?\n'));
    for (var line in lines) {
      line = line.trim();
      if (line.isEmpty || line.startsWith('#') || line.startsWith('//')) {
        continue;
      }
      final parts = line.split('=');
      if (parts.length != 2) continue;
      final key = parts[0].trim().toLowerCase();
      final val = parts[1].trim();
      final parsedVal = BigInt.tryParse(val, radix: 16);
      if (parsedVal == null) continue;

      switch (key) {
        case 'generator':
          generator = parsedVal;
          break;
        case 'slot0x18keyx':
        case 'keyx0x18':
          keyX0x18 = parsedVal;
          break;
        case 'slot0x1bkeyx':
        case 'keyx0x1b':
          keyX0x1B = parsedVal;
          break;
        case 'slot0x25keyx':
        case 'keyx0x25':
          keyX0x25 = parsedVal;
          break;
        case 'slot0x2ckeyx':
        case 'keyx0x2c':
          keyX0x2C = parsedVal;
          break;
      }
    }

    if (generator == null ||
        keyX0x18 == null ||
        keyX0x1B == null ||
        keyX0x25 == null ||
        keyX0x2C == null) {
      throw const FormatException(
          'Missing required keys (generator, slot0x18KeyX, slot0x1BKeyX, slot0x25KeyX, slot0x2CKeyX) in 3dskeys.txt');
    }

    return ThreeDsKeys(
      generator: generator,
      keyX0x18: keyX0x18,
      keyX0x1B: keyX0x1B,
      keyX0x25: keyX0x25,
      keyX0x2C: keyX0x2C,
    );
  }

  /// Derive an NCCH "NormalKey" from a KeyX and the partition's KeyY.
  ///
  /// Port of: `rol((rol(KeyX, 2, 128) ^ KeyY) + Const, 87, 128)`.
  BigInt deriveNormalKey(BigInt keyX, BigInt keyY) {
    final inner = (rotateLeft(keyX, 2, 128) ^ keyY) + generator;
    return rotateLeft(inner, 87, 128);
  }

  /// Map an NCCH crypto-method byte (`ncchFlags[3]`) to its KeyX.
  BigInt keyXForCryptoMethod(int cryptoMethod) {
    switch (cryptoMethod) {
      case 0x00:
        return keyX0x2C; // Original key
      case 0x01:
        return keyX0x25; // 7.x key
      case 0x0A:
        return keyX0x18; // New 3DS 9.3 key
      case 0x0B:
        return keyX0x1B; // New 3DS 9.6 key
      default:
        return keyX0x2C;
    }
  }
}

/// CTR counter constants joined with the TitleID to form each region's IV.
/// These are the big-endian reads of `01..`, `02..`, `03..` in the Python code,
/// i.e. the byte sits in the high byte of the low 64-bit half of the IV.
final BigInt plainCounter = BigInt.parse('0100000000000000', radix: 16);
final BigInt exefsCounter = BigInt.parse('0200000000000000', radix: 16);
final BigInt romfsCounter = BigInt.parse('0300000000000000', radix: 16);

