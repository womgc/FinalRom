import 'dart:async';
import 'dart:typed_data';

import 'aes_ctr.dart';
import 'big_int_ops.dart';
import 'exceptions.dart';
import 'io_support.dart';
import 'keys.dart';
import 'ncch_partition.dart';
import 'progress.dart';
import 'rom_file.dart';

const int _oneMb = 1024 * 1024;

/// Filename of the executable inside ExeFS: `.code\0\0\0`.
const List<int> _codeFilename = [0x2E, 0x63, 0x6F, 0x64, 0x65, 0x00, 0x00, 0x00];

/// Encrypt a 3DS NCSD ROM. Dart port of `b3DSEncrypt.py`.
///
/// Re-applies retail encryption to a decrypted ROM, using the backup NCCH
/// header flags (at 0x1188) to choose the original key for each partition.
///
/// By default ([inPlace] = false) the original is copied to a new file
/// (`outputPath`, or `<name>-encrypted.3ds`) and only the copy is modified. Set
/// [inPlace] = true to edit the original directly like the Python script.
///
/// Returns the path that was written. [onProgress] receives structured events
/// equivalent to the script's console output.
Future<String> encrypt3ds(
  String inputPath, {
  required ThreeDsKeys keys,
  String? outputPath,
  bool inPlace = false,
  ProgressCallback? onProgress,
}) async {
  final targetPath =
      await resolveTarget(inputPath, outputPath, inPlace, 'encrypted');
  final rom = await RomFile.open(targetPath);
  try {
    await _encryptRom(rom, keys, onProgress);
  } finally {
    await rom.flush();
    await rom.close();
  }
  return targetPath;
}

Future<void> _encryptRom(RomFile rom, ThreeDsKeys keys, ProgressCallback? onProgress) async {
  void report(CryptoProgress progress) => onProgress?.call(progress);

  if (!magicEquals(rom.readAt(0x100, 4), 'NCSD')) {
    throw const ThreeDsCryptoException('Not a 3DS Rom?');
  }

  final ncsdFlags = rom.readBytes(0x188, 8);
  final sectorsize = 0x200 * (1 << ncsdFlags[6]);

  // Backup NCCH header flags — the source of truth for which key to re-apply.
  final backupFlags = rom.readBytes(0x1188, 8);

  var globalTotalMb = 0;
  final partitionsToEncrypt = <int, PartitionInfo>{};

  for (var p = 0; p < 8; p++) {
    final partOff = rom.readUint32LE(0x120 + p * 0x08);
    final partLen = rom.readUint32LE(0x120 + p * 0x08 + 0x04);
    final partBase = partOff * sectorsize;

    if (partOff <= 0) continue;
    try {
      if (!magicEquals(rom.readAt(partBase + 0x100, 4), 'NCCH')) continue;
      final partitionFlags = rom.readBytes(partBase + 0x188, 8);
      if (partitionFlags[7] & 0x04 == 0) continue; // Already encrypted

      final info = PartitionInfo.read(rom, partOff, partLen, sectorsize);
      partitionsToEncrypt[p] = info;

      if (info.exefsLen > 0) {
        final exefsBytes = (info.exefsLen - 1) * sectorsize;
        // Count the trailing partial MB too, so the total matches the work the
        // body loop actually reports (mirrors RomFS's `+ 1`).
        globalTotalMb +=
            exefsBytes ~/ _oneMb + (exefsBytes % _oneMb > 0 ? 1 : 0);
      }
      if (info.romfsOff != 0) {
        final romfsSizeTotalMb = (info.romfsLen * sectorsize) ~/ _oneMb + 1;
        globalTotalMb += romfsSizeTotalMb;
      }
    } catch (_) {}
  }

  var globalProcessedMb = 0;

  for (var p = 0; p < 8; p++) {
    final partOff = rom.readUint32LE(0x120 + p * 0x08);
    final partBase = partOff * sectorsize;

    if (partBase <= 0) {
      report(CryptoProgress(
        partition: p,
        phase: CryptoPhase.partition,
        currentMb: globalProcessedMb,
        totalMb: globalTotalMb,
        message: 'Partition $p Not found... Skipping...',
      ));
      continue;
    }

    Uint8List partitionFlags;
    try {
      partitionFlags = rom.readBytes(partBase + 0x188, 8);
    } catch (_) {
      // Partition offset points past EOF (truncated/corrupt ROM); skip it
      // instead of aborting the whole encrypt, matching the pre-scan guard.
      report(CryptoProgress(
        partition: p,
        phase: CryptoPhase.partition,
        currentMb: globalProcessedMb,
        totalMb: globalTotalMb,
        message: 'Partition $p Unable to read partition flags... Skipping...',
      ));
      continue;
    }

    if (partitionFlags[7] & 0x04 == 0) {
      report(CryptoProgress(
        partition: p,
        phase: CryptoPhase.partition,
        currentMb: globalProcessedMb,
        totalMb: globalTotalMb,
        message: 'Partition $p: Already Encrypted?...',
      ));
      continue;
    }
    if (!magicEquals(rom.readAt(partBase + 0x100, 4), 'NCCH')) {
      report(CryptoProgress(
        partition: p,
        phase: CryptoPhase.partition,
        currentMb: globalProcessedMb,
        totalMb: globalTotalMb,
        message: 'Partition $p Unable to read NCCH header',
      ));
      continue;
    }

    final info = partitionsToEncrypt[p];
    if (info == null) continue;
    final backupCryptoMethod = backupFlags[3];

    // Derive keys from the backup crypto method; fixed-key (0-key) overrides.
    var normalKey2C = info.normalKey2C(keys);
    var normalKey =
        keys.deriveNormalKey(keys.keyXForCryptoMethod(backupCryptoMethod), info.keyY);
    if (backupFlags[7] & 0x01 != 0) {
      normalKey = BigInt.zero;
      normalKey2C = BigInt.zero;
    }

    // ── ExHeader ──────────────────────────────────────────────────────────
    if (info.exhdrLen > 0) {
      final pos = (info.partOffSectors + 1) * sectorsize;
      final cipher = AesCtr.fromBigInts(normalKey2C, info.plainIV);
      rom.writeAt(pos, cipher.process(rom.readAt(pos, 0x800)));
      report(CryptoProgress(
        partition: p,
        phase: CryptoPhase.exHeader,
        currentMb: globalProcessedMb,
        totalMb: globalTotalMb,
        message: 'Partition $p ExeFS: Encrypting: ExHeader',
      ));
    }

    // ── ExeFS ─────────────────────────────────────────────────────────────
    if (info.exefsLen > 0) {
      // For 7.x / New3DS keys, re-key `.code` to its real key BEFORE the table
      // and body are encrypted (the filename table is still plaintext here).
      if (backupCryptoMethod == 0x01 ||
          backupCryptoMethod == 0x0A ||
          backupCryptoMethod == 0x0B) {
        await _recodeDotCode(
          rom: rom,
          info: info,
          sectorsize: sectorsize,
          normalKey: normalKey,
          normalKey2C: normalKey2C,
          partition: p,
          globalProcessedMb: globalProcessedMb,
          globalTotalMb: globalTotalMb,
          report: report,
        );
      }

      // Encrypt the ExeFS filename table (first sector) with KeyX 0x2C.
      final tablePos = (info.partOffSectors + info.exefsOff) * sectorsize;
      final tableCipher = AesCtr.fromBigInts(normalKey2C, info.exefsIV);
      rom.writeAt(tablePos, tableCipher.process(rom.readAt(tablePos, sectorsize)));
      report(CryptoProgress(
        partition: p,
        phase: CryptoPhase.exeFsFilenameTable,
        currentMb: globalProcessedMb,
        totalMb: globalTotalMb,
        message: 'Partition $p ExeFS: Encrypting: ExeFS Filename Table',
      ));

      // Encrypt the ExeFS body with KeyX 0x2C.
      final exefsSizeM = ((info.exefsLen - 1) * sectorsize) ~/ _oneMb;
      final exefsSizeB = ((info.exefsLen - 1) * sectorsize) % _oneMb;
      final ctrOffset = sectorsize ~/ 0x10;
      final counter = (info.exefsIV + BigInt.from(ctrOffset)) & mask128;
      final cipher = AesCtr.fromBigInts(normalKey2C, counter);
      var pos = (info.partOffSectors + info.exefsOff + 1) * sectorsize;
      for (var i = 0; i < exefsSizeM; i++) {
        rom.writeAt(pos, cipher.process(rom.readAt(pos, _oneMb)));
        pos += _oneMb;
        report(CryptoProgress(
          partition: p,
          phase: CryptoPhase.exeFs,
          currentMb: globalProcessedMb + i,
          totalMb: globalTotalMb,
          message: 'Partition $p ExeFS: Encrypting: $i / ${exefsSizeM + 1} mb',
        ));
        await _yield();
      }
      if (exefsSizeB > 0) {
        rom.writeAt(pos, cipher.process(rom.readAt(pos, exefsSizeB)));
      }
      globalProcessedMb += exefsSizeM + (exefsSizeB > 0 ? 1 : 0);
      report(CryptoProgress(
        partition: p,
        phase: CryptoPhase.exeFs,
        currentMb: globalProcessedMb,
        totalMb: globalTotalMb,
        done: true,
        message:
            'Partition $p ExeFS: Encrypting: ${exefsSizeM + 1} / ${exefsSizeM + 1} mb... Done',
      ));
    } else {
      report(CryptoProgress(
        partition: p,
        phase: CryptoPhase.exeFs,
        currentMb: globalProcessedMb,
        totalMb: globalTotalMb,
        message: 'Partition $p ExeFS: No Data... Skipping...',
      ));
    }

    // ── RomFS ─────────────────────────────────────────────────────────────
    if (info.romfsOff != 0) {
      const romfsBlockSize = 16; // MB
      final romfsSizeM = (info.romfsLen * sectorsize) ~/ (romfsBlockSize * _oneMb);
      final romfsSizeB = (info.romfsLen * sectorsize) % (romfsBlockSize * _oneMb);
      final romfsSizeTotalMb = (info.romfsLen * sectorsize) ~/ _oneMb + 1;

      // RomFS on partitions 1+ always uses KeyX 0x2C.
      var romfsKey = normalKey;
      if (p > 0) {
        romfsKey = keys.deriveNormalKey(keys.keyX0x2C, info.keyY);
      }

      final cipher = AesCtr.fromBigInts(romfsKey, info.romfsIV);
      var pos = (info.partOffSectors + info.romfsOff) * sectorsize;
      for (var i = 0; i < romfsSizeM; i++) {
        rom.writeAt(pos, cipher.process(rom.readAt(pos, romfsBlockSize * _oneMb)));
        pos += romfsBlockSize * _oneMb;
        report(CryptoProgress(
          partition: p,
          phase: CryptoPhase.romFs,
          currentMb: globalProcessedMb + i * romfsBlockSize,
          totalMb: globalTotalMb,
          message:
              'Partition $p RomFS: Encrypting: ${i * romfsBlockSize} / $romfsSizeTotalMb mb',
        ));
        await _yield();
      }
      if (romfsSizeB > 0) {
        rom.writeAt(pos, cipher.process(rom.readAt(pos, romfsSizeB)));
      }
      globalProcessedMb += romfsSizeTotalMb;
      report(CryptoProgress(
        partition: p,
        phase: CryptoPhase.romFs,
        currentMb: globalProcessedMb,
        totalMb: globalTotalMb,
        done: true,
        message:
            'Partition $p RomFS: Encrypting: $romfsSizeTotalMb / $romfsSizeTotalMb mb... Done',
      ));
    } else {
      report(CryptoProgress(
        partition: p,
        phase: CryptoPhase.romFs,
        currentMb: globalProcessedMb,
        totalMb: globalTotalMb,
        message: 'Partition $p RomFS: No Data... Skipping...',
      ));
    }

    // ── Header flags ──────────────────────────────────────────────────────
    // crypto-method byte: 0x00 for partitions 1+, restored backup value for p0.
    rom.writeAt(
      partBase + 0x18B,
      [p > 0 ? 0x00 : backupCryptoMethod],
    );
    // flags byte: clear FixedCryptoKey/NewKeyY/NoCrypto, then OR in the backup's
    // FixedCryptoKey/NewKeyY bits.
    var flag = partitionFlags[7];
    flag = flag & ((0x01 | 0x20 | 0x04) ^ 0xFF);
    flag = flag | ((0x01 | 0x20) & backupFlags[7]);
    rom.writeAt(partBase + 0x18F, [flag]);
  }

  report(CryptoProgress(
    partition: -1,
    phase: CryptoPhase.done,
    currentMb: globalProcessedMb,
    totalMb: globalTotalMb,
    done: true,
    message: 'Done...',
  ));
}

/// Re-key the `.code` file: encrypt with [normalKey] then XOR out [normalKey2C],
/// so that after the subsequent 0x2C body pass it ends up under its real key.
Future<void> _recodeDotCode({
  required RomFile rom,
  required PartitionInfo info,
  required int sectorsize,
  required BigInt normalKey,
  required BigInt normalKey2C,
  required int partition,
  required int globalProcessedMb,
  required int globalTotalMb,
  required void Function(CryptoProgress) report,
}) async {
  for (var j = 0; j < 10; j++) {
    final entryPos = (info.partOffSectors + info.exefsOff) * sectorsize + j * 0x10;
    final entry = rom.readAt(entryPos, 16);
    if (!bytesEqual(entry, _codeFilename, 8)) continue;

    final entryView = ByteData.sublistView(entry);
    final codeFileOff = entryView.getUint32(8, Endian.little);
    final codeFileLen = entryView.getUint32(12, Endian.little);
    final dataLenM = codeFileLen ~/ _oneMb;
    final dataLenB = codeFileLen % _oneMb;
    final ctrOffset = (codeFileOff + sectorsize) ~/ 0x10;
    final counter = (info.exefsIV + BigInt.from(ctrOffset)) & mask128;
    final cipher = AesCtr.fromBigInts(normalKey, counter);
    final cipher2C = AesCtr.fromBigInts(normalKey2C, counter);

    var pos = ((info.partOffSectors + info.exefsOff) + 1) * sectorsize + codeFileOff;
    for (var i = 0; i < dataLenM; i++) {
      final data = rom.readAt(pos, _oneMb);
      rom.writeAt(pos, cipher2C.process(cipher.process(data)));
      pos += _oneMb;
      report(CryptoProgress(
        partition: partition,
        phase: CryptoPhase.exeFsCode,
        currentMb: globalProcessedMb,
        totalMb: globalTotalMb,
        message:
            'Partition $partition ExeFS: Encrypting: .code... $i / ${dataLenM + 1} mb...',
      ));
      await _yield();
    }
    if (dataLenB > 0) {
      final data = rom.readAt(pos, dataLenB);
      rom.writeAt(pos, cipher2C.process(cipher.process(data)));
    }
    report(CryptoProgress(
      partition: partition,
      phase: CryptoPhase.exeFsCode,
      currentMb: globalProcessedMb,
      totalMb: globalTotalMb,
      done: true,
      message:
          'Partition $partition ExeFS: Encrypting: .code... ${dataLenM + 1} / ${dataLenM + 1} mb... Done!',
    ));
  }
}

/// Yield to the event loop between heavy chunks (see decryptor for rationale).
Future<void> _yield() => Future<void>.delayed(Duration.zero);
