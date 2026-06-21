/// Thrown when the input is not a recognisable 3DS NCSD ROM.
class ThreeDsCryptoException implements Exception {
  final String message;
  const ThreeDsCryptoException(this.message);

  @override
  String toString() => 'ThreeDsCryptoException: $message';
}
