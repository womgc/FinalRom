import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import 'big_int_ops.dart';

/// AES-128 in CTR mode, the equivalent of pycryptodome's
/// `AES.new(key, AES.MODE_CTR, counter=Counter.new(128, initial_value=iv))`.
///
/// The whole 16-byte IV is treated as a big-endian 128-bit counter that
/// increments by one per block, matching `Counter.new(128, ...)`. Because CTR
/// is a stream cipher, encryption and decryption are the identical XOR
/// operation, and the cipher keeps its counter state across [process] calls —
/// so callers can feed the data in chunks (the 1 MB / 16 MB loops in the
/// original scripts) and the keystream stays continuous.
class AesCtr {
  final CTRStreamCipher _cipher;

  AesCtr._(this._cipher);

  /// Build a cipher from a 128-bit key value and a 128-bit initial counter
  /// value (both [BigInt]). The `forEncryption` flag is irrelevant for CTR but
  /// is required by the pointycastle API.
  factory AesCtr.fromBigInts(BigInt key, BigInt counter) {
    final cipher = CTRStreamCipher(AESEngine())
      ..init(
        true,
        ParametersWithIV<KeyParameter>(
          KeyParameter(bigIntTo16Bytes(key)),
          bigIntTo16Bytes(counter),
        ),
      );
    return AesCtr._(cipher);
  }

  /// XOR [data] with the next bytes of the keystream and return the result.
  /// Advances the internal counter so subsequent calls continue the stream.
  Uint8List process(Uint8List data) => _cipher.process(data);
}
