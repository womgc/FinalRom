import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// Parses a Switch `prod.keys` file and derives the per-content keys needed to
/// decrypt NCA sections for NSZ compression.
///
/// `prod.keys` is a plain-text `name = hexvalue` list. The keys this needs:
///   * `header_key` (32 bytes) — NCA header AES-XTS key.
///   * `key_area_key_application_XX` / `_ocean_XX` / `_system_XX` (16 bytes) —
///     the KEK that unwraps an NCA's encrypted key area, per master-key
///     generation `XX` and per key-area index (0=application, 1=ocean,
///     2=system).
///   * `titlekek_XX` (16 bytes) — unwraps a ticket's title key (titlekey
///     crypto), per generation.
///
/// The app must never embed keys: a [SwitchKeys] is always built from a file
/// the user supplies.
class SwitchKeys {
  final Map<String, Uint8List> _keys;

  SwitchKeys._(this._keys);

  /// Parses the text content of a `prod.keys` file.
  factory SwitchKeys.parse(String contents) {
    final keys = <String, Uint8List>{};
    for (final rawLine in contents.split('\n')) {
      final line = rawLine.trim();
      if (line.isEmpty || line.startsWith(';') || line.startsWith('#')) {
        continue;
      }
      final separator = line.indexOf('=');
      if (separator < 0) continue;
      final name = line.substring(0, separator).trim().toLowerCase();
      final value = line.substring(separator + 1).trim();
      final bytes = _tryParseHex(value);
      if (bytes != null) {
        keys[name] = bytes;
      }
    }
    return SwitchKeys._(keys);
  }

  Uint8List _require(String name) {
    final value = _keys[name];
    if (value == null) {
      throw SwitchKeysException('Missing key "$name" in prod.keys.');
    }
    return value;
  }

  /// The 32-byte NCA header AES-XTS key.
  Uint8List get headerKey => _require('header_key');

  static const List<String> _keyAreaKekNames = [
    'key_area_key_application',
    'key_area_key_ocean',
    'key_area_key_system',
  ];

  /// The key-area KEK for [keyIndex] (0..2) and master-key [generation].
  Uint8List keyAreaKek(int keyIndex, int generation) {
    if (keyIndex < 0 || keyIndex >= _keyAreaKekNames.length) {
      throw SwitchKeysException('Invalid key-area index $keyIndex.');
    }
    final name =
        '${_keyAreaKekNames[keyIndex]}_${generation.toRadixString(16).padLeft(2, '0')}';
    return _require(name);
  }

  /// The titlekek for master-key [generation].
  Uint8List titlekek(int generation) =>
      _require('titlekek_${generation.toRadixString(16).padLeft(2, '0')}');

  /// Unwraps a 16-byte [wrappedKey] with [kek] using AES-128-ECB (the
  /// single-block primitive used throughout the NCA key hierarchy).
  static Uint8List aesEcbDecrypt(Uint8List kek, Uint8List wrappedKey) {
    if (kek.length != 16 || wrappedKey.length != 16) {
      throw ArgumentError('AES-ECB unwrap expects 16-byte key and block.');
    }
    final cipher = AESEngine()..init(false, KeyParameter(kek));
    final out = Uint8List(16);
    cipher.processBlock(wrappedKey, 0, out, 0);
    return out;
  }
}

/// A parsed Switch ticket (`.tik`): the encrypted title key plus the
/// master-key revision used to unwrap it. Offsets follow the ES-ticket
/// specification and are derived dynamically from the signature type so
/// different ticket formats (RSA-2048, RSA-4096, ECDSA) are handled
/// correctly — matching Ticket.py's `seekStart()` logic.
class SwitchTicket {
  final Uint8List encryptedTitleKey; // 16 bytes
  final Uint8List rightsId; // 16 bytes

  /// The 0-based master-key index used to decrypt [encryptedTitleKey].
  ///
  /// The reference reads `masterKeyRevision` from the ticket body and uses
  /// `masterKeyRevision - 1` as the titlekek index. This is NOT the same as
  /// `rightsId[15]` (the rights-id generation byte), which is one higher.
  final int generation;

  SwitchTicket._({required this.encryptedTitleKey, required this.rightsId, required this.generation});

  factory SwitchTicket.parse(Uint8List data) {
    if (data.length < 0x200) {
      throw SwitchKeysException('Ticket is too small to be valid.');
    }

    // Signature type at byte 0 determines the body start offset.
    // Matches the reference Ticket.py signatureSizes + padding calculation.
    final sigType = ByteData.sublistView(data, 0, 4).getUint32(0, Endian.little);
    final int sigSize;
    switch (sigType) {
      case 0x10000: // RSA_4096_SHA1
      case 0x10003: // RSA_4096_SHA256
        sigSize = 0x200;
      case 0x10001: // RSA_2048_SHA1
      case 0x10004: // RSA_2048_SHA256
        sigSize = 0x100;
      case 0x10002: // ECDSA_SHA1
      case 0x10005: // ECDSA_SHA256
        sigSize = 0x3C;
      default:
        throw SwitchKeysException(
            'Unknown ticket signature type: 0x${sigType.toRadixString(16)}');
    }

    // Padding aligns the body to a 0x40-byte boundary after [4 + sigSize].
    final padding = 0x40 - ((sigSize + 4) % 0x40);
    final bodyStart = 4 + sigSize + padding;

    if (data.length < bodyStart + 0x170) {
      throw SwitchKeysException('Ticket body too short.');
    }

    // Encrypted title key is at body + 0x40 (16 bytes).
    final encTitleKey = Uint8List.sublistView(data, bodyStart + 0x40, bodyStart + 0x50);

    // Rights ID is at body + 0x160 (16 bytes).
    final rights = Uint8List.sublistView(data, bodyStart + 0x160, bodyStart + 0x170);

    // masterKeyRevision at body + 0x145 mirrors `getMasterKeyRevision()` in
    // Ticket.py (reads one byte; if zero, reads the next byte instead).
    // The titlekek index = masterKeyRevision - 1.
    int mkRev = data[bodyStart + 0x145];
    if (mkRev == 0 && bodyStart + 0x146 < data.length) {
      mkRev = data[bodyStart + 0x146];
    }
    final gen = mkRev > 0 ? mkRev - 1 : 0;

    return SwitchTicket._(
      encryptedTitleKey: encTitleKey,
      rightsId: rights,
      generation: gen,
    );
  }

  /// Decrypts the title key with the matching titlekek from [keys].
  Uint8List decryptTitleKey(SwitchKeys keys) =>
      SwitchKeys.aesEcbDecrypt(keys.titlekek(generation), encryptedTitleKey);
}

class SwitchKeysException implements Exception {
  final String message;
  SwitchKeysException(this.message);
  @override
  String toString() => 'SwitchKeysException: $message';
}

Uint8List? _tryParseHex(String value) {
  if (value.isEmpty || value.length.isOdd) return null;
  final out = Uint8List(value.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    final byte = int.tryParse(value.substring(i * 2, i * 2 + 2), radix: 16);
    if (byte == null) return null;
    out[i] = byte;
  }
  return out;
}
