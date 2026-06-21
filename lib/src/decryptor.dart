import 'dart:async';
import 'dart:io';
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

/// Decrypt a 3DS NCSD ROM. Dart port of `b3DSDecrypt.py`.
///
/// By default ([inPlace] = false) the original is copied to a new file
/// (`outputPath`, or `<name>-decrypted.3ds`) and only the copy is modified, so
/// the source ROM is left untouched. Set [inPlace] = true to edit the original
/// directly like the Python script.
///
/// When [trim] is true (the default) the written file is shrunk to the size
/// actually used by the partition table, dropping the trailing cartridge
/// padding — this is what makes the new file smaller than the source, matching
/// the makerom-based batch decryptors. Set [trim] = false to keep the original
/// full size (a byte-for-byte same-size decrypt, like the Python script).
///
/// Returns the path that was written. [onProgress] receives structured events
/// equivalent to the script's console output.
Future<String> decrypt3ds(
  String inputPath, {
  required ThreeDsKeys keys,
  String? outputPath,
  bool inPlace = false,
  bool trim = true,
  ProgressCallback? onProgress,
}) async {
  // Avoid copying the source just to discover it is already decrypted: scan the
  // original read-only first and bail out without writing anything.
  if (!inPlace && await _is3dsFullyDecrypted(inputPath)) {
    onProgress?.call(const CryptoProgress(
      partition: -1,
      phase: CryptoPhase.alreadyDecrypted,
      done: true,
      message: 'Already decrypted — no new file created',
    ));
    return inputPath;
  }

  final targetPath =
      await resolveTarget(inputPath, outputPath, inPlace, 'decrypted');
  final rom = await RomFile.open(targetPath);
  try {
    await _decryptRom(rom, keys, onProgress, trim: trim);
  } finally {
    await rom.flush();
    await rom.close();
  }
  return targetPath;
}

/// Whether every present NCCH partition in the ROM at [inputPath] already has
/// the NoCrypto flag set (i.e. there is nothing left to decrypt).
///
/// Reads the input read-only and mirrors the per-partition NoCrypto check in
/// [_decryptRom]. Returns false for anything that is not a recognizable NCSD
/// ROM so the normal decrypt path still surfaces the usual error.
Future<bool> _is3dsFullyDecrypted(String inputPath) async {
  final file = await File(inputPath).open(mode: FileMode.read);
  try {
    Future<Uint8List> readAt(int position, int length) async {
      await file.setPosition(position);
      return file.read(length);
    }

    final ncsdMagic = await readAt(0x100, 4);
    if (!magicEquals(ncsdMagic, 'NCSD')) return false;

    final ncsdFlags = await readAt(0x188, 8);
    final sectorsize = 0x200 * (1 << ncsdFlags[6]);

    for (var partition = 0; partition < 8; partition++) {
      final partitionTable = await readAt(0x120 + partition * 0x08, 8);
      final partOff =
          ByteData.sublistView(partitionTable).getUint32(0, Endian.little);
      if (partOff <= 0) continue;

      final partBase = partOff * sectorsize;
      final ncchMagic = await readAt(partBase + 0x100, 4);
      if (!magicEquals(ncchMagic, 'NCCH')) continue;

      final partitionFlags = await readAt(partBase + 0x188, 8);
      final isAlreadyDecrypted = partitionFlags[7] & 0x04 != 0;
      if (!isAlreadyDecrypted) return false;
    }
    return true;
  } finally {
    await file.close();
  }
}

Future<void> _decryptRom(
  RomFile rom,
  ThreeDsKeys keys,
  ProgressCallback? onProgress, {
  required bool trim,
}) async {
  void report(CryptoProgress progress) => onProgress?.call(progress);

  if (!magicEquals(rom.readAt(0x100, 4), 'NCSD')) {
    throw const ThreeDsCryptoException('Not a 3DS Rom?');
  }

  final ncsdFlags = rom.readBytes(0x188, 8);
  final sectorsize = 0x200 * (1 << ncsdFlags[6]);

  var globalTotalMb = 0;
  final partitionsToDecrypt = <int, PartitionInfo>{};

  for (var p = 0; p < 8; p++) {
    final partOff = rom.readUint32LE(0x120 + p * 0x08);
    final partLen = rom.readUint32LE(0x120 + p * 0x08 + 0x04);
    final partBase = partOff * sectorsize;

    if (partOff <= 0) continue;
    try {
      if (!magicEquals(rom.readAt(partBase + 0x100, 4), 'NCCH')) continue;
      final partitionFlags = rom.readBytes(partBase + 0x188, 8);
      if (partitionFlags[7] & 0x04 != 0) continue;

      final info = PartitionInfo.read(rom, partOff, partLen, sectorsize);
      partitionsToDecrypt[p] = info;

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
      // instead of aborting the whole decrypt, matching the pre-scan guard.
      report(CryptoProgress(
        partition: p,
        phase: CryptoPhase.partition,
        currentMb: globalProcessedMb,
        totalMb: globalTotalMb,
        message: 'Partition $p Unable to read partition flags... Skipping...',
      ));
      continue;
    }

    if (partitionFlags[7] & 0x04 != 0) {
      report(CryptoProgress(
        partition: p,
        phase: CryptoPhase.partition,
        currentMb: globalProcessedMb,
        totalMb: globalTotalMb,
        message: 'Partition $p: Already Decrypted?...',
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

    final info = partitionsToDecrypt[p];
    if (info == null) continue;
    final cryptoMethod = info.ncchFlags[3];

    // Derive the keys (NormalKey2C is always KeyX 0x2C; NormalKey depends on the
    // partition's crypto method, or is zero for the fixed-key case).
    var normalKey2C = info.normalKey2C(keys);
    BigInt normalKey;
    if (info.ncchFlags[7] & 0x01 != 0) {
      normalKey = BigInt.zero;
      normalKey2C = BigInt.zero;
      if (p == 0) {
        report(CryptoProgress(
          partition: 0,
          phase: CryptoPhase.info,
          currentMb: globalProcessedMb,
          totalMb: globalTotalMb,
          message: 'Encryption Method: Zero Key',
        ));
      }
    } else {
      normalKey = keys.deriveNormalKey(keys.keyXForCryptoMethod(cryptoMethod), info.keyY);
      if (p == 0) {
        report(CryptoProgress(
          partition: 0,
          phase: CryptoPhase.info,
          currentMb: globalProcessedMb,
          totalMb: globalTotalMb,
          message: 'Encryption Method: ${cryptoMethodName(cryptoMethod)}',
        ));
      }
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
        message: 'Partition $p ExeFS: Decrypting: ExHeader',
      ));
    }

    // ── ExeFS ─────────────────────────────────────────────────────────────
    if (info.exefsLen > 0) {
      // Decrypt the ExeFS filename table (first sector) with KeyX 0x2C.
      final tablePos = (info.partOffSectors + info.exefsOff) * sectorsize;
      final tableCipher = AesCtr.fromBigInts(normalKey2C, info.exefsIV);
      rom.writeAt(tablePos, tableCipher.process(rom.readAt(tablePos, sectorsize)));
      report(CryptoProgress(
        partition: p,
        phase: CryptoPhase.exeFsFilenameTable,
        currentMb: globalProcessedMb,
        totalMb: globalTotalMb,
        message: 'Partition $p ExeFS: Decrypting: ExeFS Filename Table',
      ));

      // For 7.x / New3DS keys, re-key the `.code` file from NormalKey to 0x2C so
      // the whole ExeFS becomes uniformly 0x2C-encrypted before the body pass.
      if (cryptoMethod == 0x01 || cryptoMethod == 0x0A || cryptoMethod == 0x0B) {
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

      // Decrypt the ExeFS body with KeyX 0x2C.
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
          message: 'Partition $p ExeFS: Decrypting: $i / ${exefsSizeM + 1} mb',
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
            'Partition $p ExeFS: Decrypting: ${exefsSizeM + 1} / ${exefsSizeM + 1} mb... Done',
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

      // RomFS on partitions 1+ always uses KeyX 0x2C (mirror the encryptor).
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
              'Partition $p RomFS: Decrypting: ${i * romfsBlockSize} / $romfsSizeTotalMb mb',
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
            'Partition $p RomFS: Decrypting: $romfsSizeTotalMb / $romfsSizeTotalMb mb... Done',
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
    // crypto-method byte -> 0x00.
    rom.writeAt(partBase + 0x18B, const [0x00]);
    // flags byte: clear FixedCryptoKey (0x01) and NewKeyY (0x20), set NoCrypto.
    var flag = partitionFlags[7];
    flag = flag & ((0x01 | 0x20) ^ 0xFF);
    flag = flag | 0x04;
    rom.writeAt(partBase + 0x18F, [flag]);
  }

  // ── Trim trailing padding ───────────────────────────────────────────────
  // Decryption is a same-size transform; the size win comes from dropping the
  // unused cartridge padding after the last partition, exactly like a makerom
  // -f cci repack. The NCSD header's image-size field (0x104) is left as-is,
  // matching standard 3DS ROM trimmers.
  if (trim) {
    final usedSize = _usedSizeInBytes(rom, sectorsize);
    final originalSize = rom.lengthSync;
    if (usedSize > 0 && usedSize < originalSize) {
      await rom.flush();
      rom.truncate(usedSize);
      report(CryptoProgress(
        partition: -1,
        phase: CryptoPhase.trim,
        currentMb: globalProcessedMb,
        totalMb: globalTotalMb,
        message: 'Trimmed padding: $originalSize -> $usedSize bytes',
      ));
    }
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

/// Size in bytes actually occupied by the ROM: the highest partition end
/// (`offset + length`, in sectors) found in the NCSD partition table, times the
/// sector size. Everything past it is trailing cartridge padding.
int _usedSizeInBytes(RomFile rom, int sectorsize) {
  var maxEndSectors = 0;
  for (var p = 0; p < 8; p++) {
    final partOff = rom.readUint32LE(0x120 + p * 0x08);
    final partLen = rom.readUint32LE(0x120 + p * 0x08 + 0x04);
    if (partOff == 0) continue;
    final endSectors = partOff + partLen;
    if (endSectors > maxEndSectors) maxEndSectors = endSectors;
  }
  return maxEndSectors * sectorsize;
}

/// Re-key the `.code` file: decrypt with [normalKey] then re-encrypt with
/// [normalKey2C], in place, so the whole ExeFS ends up 0x2C-encrypted.
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
            'Partition $partition ExeFS: Decrypting: .code... $i / ${dataLenM + 1} mb...',
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
          'Partition $partition ExeFS: Decrypting: .code... ${dataLenM + 1} / ${dataLenM + 1} mb... Done!',
    ));
  }
}

/// Yield to the event loop between heavy chunks so progress callbacks surface
/// and the UI (when not run in an isolate) is not starved.
Future<void> _yield() => Future<void>.delayed(Duration.zero);
