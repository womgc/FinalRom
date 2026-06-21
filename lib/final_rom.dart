/// Dart port of the `b3DSDecrypt.py` / `b3DSEncrypt.py` 3DS ROM crypto scripts.
///
/// Public API:
///  * [decrypt3ds] — decrypt an NCSD ROM (default: writes a new file).
///  * [encrypt3ds] — re-encrypt a decrypted NCSD ROM (default: writes a new file).
///  * [CryptoProgress] / [ProgressCallback] — structured progress reporting.
///  * [ThreeDsCryptoException] — thrown when the input is not a 3DS ROM.
library;

export 'src/decryptor.dart' show decrypt3ds;
export 'src/encryptor.dart' show encrypt3ds;
export 'src/exceptions.dart' show ThreeDsCryptoException;
export 'src/progress.dart' show CryptoProgress, CryptoPhase, ProgressCallback;
export 'src/keys.dart' show ThreeDsKeys;
