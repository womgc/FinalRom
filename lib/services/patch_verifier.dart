import 'dart:io';
import 'dart:typed_data';
import 'package:path/path.dart' as p;
import '../patcher/checksums.dart';

enum CompatibilityResult {
  compatible,
  incompatible,
  unverifiable,
}

class PatchVerifier {
  static Future<CompatibilityResult> checkCompatibility(String patchPath, String romPath) async {
    final patchFile = File(patchPath);
    final romFile = File(romPath);

    if (!await patchFile.exists() || !await romFile.exists()) {
      return CompatibilityResult.unverifiable;
    }

    final ext = p.extension(patchPath).toLowerCase().replaceFirst('.', '');
    try {
      if (ext == 'bps' || ext == 'ups') {
        final patchLen = await patchFile.length();
        if (patchLen < 12) return CompatibilityResult.unverifiable;

        final raf = await patchFile.open(mode: FileMode.read);
        try {
          await raf.setPosition(patchLen - 12);
          final crcBytes = await raf.read(4);
          if (crcBytes.length < 4) return CompatibilityResult.unverifiable;
          final expectedCrc = ByteData.sublistView(crcBytes).getUint32(0, Endian.little);

          // Now compute the ROM's CRC32
          final actualCrc = await crc32OfFile(romFile);
          return actualCrc == expectedCrc
              ? CompatibilityResult.compatible
              : CompatibilityResult.incompatible;
        } finally {
          await raf.close();
        }
      } else if (ext == 'ppf') {
        final patchLen = await patchFile.length();
        if (patchLen < 61) return CompatibilityResult.unverifiable;

        final rafPatch = await patchFile.open(mode: FileMode.read);
        final rafRom = await romFile.open(mode: FileMode.read);
        try {
          // Check version
          await rafPatch.setPosition(0);
          final magicBytes = await rafPatch.read(5);
          if (magicBytes.length < 5) return CompatibilityResult.unverifiable;
          
          if (magicBytes[0] != 0x50 || magicBytes[1] != 0x50 || magicBytes[2] != 0x46) {
            return CompatibilityResult.unverifiable;
          }
          final verChar = magicBytes[3]; // '1', '2', '3'
          final version = verChar - 0x30;

          if (version == 2) {
            // PPF2
            await rafPatch.setPosition(56);
            final lenBytes = await rafPatch.read(4);
            if (lenBytes.length < 4) return CompatibilityResult.unverifiable;
            final romSize = _readLEUint32(lenBytes);
            final romLength = await romFile.length();
            if (romSize != romLength) {
              return CompatibilityResult.incompatible;
            }

            final patchBlock = await rafPatch.read(1024);
            await rafRom.setPosition(0x9320);
            final romBlock = await rafRom.read(1024);
            if (patchBlock.length == 1024 && romBlock.length == 1024) {
              return _bytesEqual(patchBlock, romBlock)
                  ? CompatibilityResult.compatible
                  : CompatibilityResult.incompatible;
            }
          } else if (version == 3) {
            // PPF3
            await rafPatch.setPosition(56);
            final imageType = await rafPatch.readByte();
            final blockCheck = await rafPatch.readByte();
            if (blockCheck == 0x01) {
              await rafPatch.setPosition(60);
              final patchBlock = await rafPatch.read(1024);
              final offset = imageType == 0x01 ? 0x80A0 : 0x9320;
              await rafRom.setPosition(offset);
              final romBlock = await rafRom.read(1024);
              if (patchBlock.length == 1024 && romBlock.length == 1024) {
                return _bytesEqual(patchBlock, romBlock)
                    ? CompatibilityResult.compatible
                    : CompatibilityResult.incompatible;
              }
            }
          }
        } finally {
          await rafPatch.close();
          await rafRom.close();
        }
      }
    } catch (_) {
      // ignore
    }

    return CompatibilityResult.unverifiable;
  }

  static int _readLEUint32(List<int> bytes) {
    if (bytes.length < 4) return 0;
    return ByteData.sublistView(Uint8List.fromList(bytes)).getUint32(0, Endian.little);
  }

  static bool _bytesEqual(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
