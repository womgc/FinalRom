import 'dart:io';
import 'dart:isolate';

import '../switch/keys.dart';
import '../switch/unmerger.dart';
import 'switch_progress.dart';

class UnmergeParams {
  final String inputNspPath;
  final String outputDir;
  final String keysPath;
  final SendPort sendPort;

  UnmergeParams({
    required this.inputNspPath,
    required this.outputDir,
    required this.keysPath,
    required this.sendPort,
  });
}

/// Runs an NSP unmerge off the UI isolate, streaming [SwitchProgress] events
/// and a final [UnmergeResultMessage] over the [SendPort]. Mirrors the
/// structure of the other workers; meant to be an [Isolate.spawn] entry point.
class NspUnmergeWorker {
  static Future<void> runUnmerge(UnmergeParams params) async {
    try {
      final keysFile = File(params.keysPath);
      if (!await keysFile.exists()) {
        throw ArgumentError('prod.keys file not found at "${params.keysPath}".');
      }
      final keys = SwitchKeys.parse(await keysFile.readAsString());

      final result = await NspUnmerger.unmerge(
        params.inputNspPath,
        params.outputDir,
        keys: keys,
        onProgress: (message, fraction) =>
            params.sendPort.send(SwitchProgress(message, fraction)),
      );
      params.sendPort.send(UnmergeResultMessage(
        success: true,
        outputs: result.outputs,
      ));
    } catch (error) {
      params.sendPort
          .send(UnmergeResultMessage(success: false, error: error.toString()));
    }
  }
}

class UnmergeResultMessage {
  final bool success;
  final List<UnmergedTitleResult>? outputs;
  final String? error;

  UnmergeResultMessage({
    required this.success,
    this.outputs,
    this.error,
  });
}
