import 'dart:io';
import 'dart:isolate';

import '../switch/keys.dart';
import '../switch/nsz_archive.dart';
import '../switch/xcz_archive.dart';
import 'switch_progress.dart';

enum NszAction { compress, decompress }

class NszParams {
  final NszAction action;
  final String inputPath;
  final String outputPath;

  /// Path to the user's `prod.keys`. Required for [NszAction.compress];
  /// ignored for [NszAction.decompress].
  final String? keysPath;

  final int level;
  final int threadCount;
  final int chunkSizeMB;
  final bool nszParallel;
  final int maxConcurrentNcas;

  /// Directory for intermediate files, created and owned by the spawning bloc
  /// so it can be cleaned up even if this isolate is killed mid-run.
  final String? tempDirPath;

  final SendPort sendPort;

  NszParams({
    required this.action,
    required this.inputPath,
    required this.outputPath,
    this.keysPath,
    this.level = 18,
    this.threadCount = 0,
    this.chunkSizeMB = 2,
    this.nszParallel = true,
    this.maxConcurrentNcas = 1 << 30,
    this.tempDirPath,
    required this.sendPort,
  });
}

/// Runs NSP→NSZ compression or NSZ→NSP decompression off the UI isolate,
/// streaming [SwitchProgress] events and a final [NszResultMessage] over the
/// [SendPort]. Meant to be an [Isolate.spawn] entry point.
class NszWorker {
  static Future<void> runNsz(NszParams params) async {
    void onProgress(String message, double fraction) =>
        params.sendPort.send(SwitchProgress(message, fraction));

    try {
      final isXci = params.inputPath.toLowerCase().endsWith('.xci');
      final isXcz = params.inputPath.toLowerCase().endsWith('.xcz');

      switch (params.action) {
        case NszAction.compress:
          final keysPath = params.keysPath;
          if (keysPath == null) {
            throw ArgumentError(
                'Compressing requires a prod.keys file.');
          }
          final keysFile = File(keysPath);
          if (!await keysFile.exists()) {
            throw ArgumentError('prod.keys file not found at "$keysPath".');
          }
          final keys = SwitchKeys.parse(await keysFile.readAsString());
          if (isXci) {
            await XczArchive.compress(
              inputXciPath: params.inputPath,
              outputPath: params.outputPath,
              keys: keys,
              level: params.level,
              threadCount: params.threadCount,
              chunkSizeMB: params.chunkSizeMB,
              keepPartitions: false,
              tempDirPath: params.tempDirPath,
              onProgress: onProgress,
            );
          } else {
            await NszArchive.compress(
              inputNspPath: params.inputPath,
              outputPath: params.outputPath,
              keys: keys,
              level: params.level,
              threadCount: params.threadCount,
              chunkSizeMB: params.chunkSizeMB,
              nszParallel: params.nszParallel,
              maxConcurrentNcas: params.maxConcurrentNcas,
              tempDirPath: params.tempDirPath,
              onProgress: onProgress,
            );
          }
        case NszAction.decompress:
          if (isXcz) {
            await XczArchive.decompress(
              inputXczPath: params.inputPath,
              outputPath: params.outputPath,
              tempDirPath: params.tempDirPath,
              onProgress: onProgress,
            );
          } else {
            await NszArchive.decompress(
              inputNszPath: params.inputPath,
              outputPath: params.outputPath,
              tempDirPath: params.tempDirPath,
              onProgress: onProgress,
            );
          }
      }
      params.sendPort
          .send(NszResultMessage(success: true, outputPath: params.outputPath));
    } catch (error) {
      params.sendPort
          .send(NszResultMessage(success: false, error: error.toString()));
    }
  }
}

class NszResultMessage {
  final bool success;
  final String? outputPath;
  final String? error;

  NszResultMessage({required this.success, this.outputPath, this.error});
}
