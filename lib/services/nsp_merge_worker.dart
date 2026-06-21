import 'dart:isolate';

import '../switch/merger.dart';
import 'switch_progress.dart';

class MergeParams {
  /// All NSPs to merge; the first is treated as the base.
  final List<String> inputNspPaths;
  final String outputPath;
  final SendPort sendPort;

  MergeParams({
    required this.inputNspPaths,
    required this.outputPath,
    required this.sendPort,
  });
}

/// Runs an NSP merge off the UI isolate, streaming [SwitchProgress] events and a
/// final [MergeResultMessage] over the [SendPort]. Mirrors the structure of the
/// other workers; meant to be an [Isolate.spawn] entry point.
class NspMergeWorker {
  static Future<void> runMerge(MergeParams params) async {
    try {
      final result = await NspMerger.merge(
        params.inputNspPaths,
        params.outputPath,
        onProgress: (message, fraction) =>
            params.sendPort.send(SwitchProgress(message, fraction)),
      );
      params.sendPort.send(MergeResultMessage(
        success: true,
        outputPath: result.outputPath,
        memberCount: result.memberCount,
      ));
    } catch (error) {
      params.sendPort
          .send(MergeResultMessage(success: false, error: error.toString()));
    }
  }
}

class MergeResultMessage {
  final bool success;
  final String? outputPath;
  final int? memberCount;
  final String? error;

  MergeResultMessage({
    required this.success,
    this.outputPath,
    this.memberCount,
    this.error,
  });
}
