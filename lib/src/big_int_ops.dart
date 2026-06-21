import 'dart:typed_data';

/// 128-bit integer helpers used by the 3DS key-scrambling algorithm.
///
/// Dart's native `int` is 64-bit, so every value that the original Python
/// scripts treated as a 128-bit number (keys, IVs, CTR counters) is a [BigInt]
/// here. These helpers are direct ports of the `rol` lambda and `to_bytes`
/// function from `b3DSDecrypt.py` / `b3DSEncrypt.py`.

/// Bit mask that keeps the low `maxBits` bits of a [BigInt].
BigInt maskFor(int maxBits) => (BigInt.one << maxBits) - BigInt.one;

/// Mask for the 128-bit values used throughout the 3DS crypto code.
final BigInt mask128 = maskFor(128);

/// Rotate-left within a fixed bit width.
///
/// Port of the Python lambda:
/// ```python
/// rol = lambda val, r_bits, max_bits: \
///     (val << r_bits % max_bits) & (2 ** max_bits - 1) | \
///     ((val & (2 ** max_bits - 1)) >> (max_bits - (r_bits % max_bits)))
/// ```
/// The left half masks *after* shifting and the right half masks *before*
/// shifting, so an input wider than `maxBits` (as produced by the unmasked
/// `+ Constant` in the key derivation) is handled identically to Python.
BigInt rotateLeft(BigInt value, int rotateBits, int maxBits) {
  final mask = maskFor(maxBits);
  final shift = rotateBits % maxBits;
  final left = (value << shift) & mask;
  final right = (value & mask) >> (maxBits - shift);
  return left | right;
}

/// Convert a [BigInt] to its 16-byte big-endian representation (the low 128
/// bits), matching the Python `to_bytes` helper which builds the value
/// little-endian byte-by-byte and then reverses it.
Uint8List bigIntTo16Bytes(BigInt value) {
  final out = Uint8List(16);
  final byteMask = BigInt.from(0xFF);
  var tmp = value;
  for (var i = 15; i >= 0; i--) {
    out[i] = (tmp & byteMask).toInt();
    tmp = tmp >> 8;
  }
  return out;
}

/// Build a [BigInt] from big-endian bytes (used for reading the `>QQ` 128-bit
/// fields such as KeyY and the hardware constant).
BigInt bigIntFromBytesBE(List<int> bytes) {
  var result = BigInt.zero;
  for (final byte in bytes) {
    result = (result << 8) | BigInt.from(byte);
  }
  return result;
}
