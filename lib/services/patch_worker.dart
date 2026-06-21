import 'dart:io';
import 'dart:isolate';
import '../patcher/patcher.dart';
import '../patcher/patcher_factory.dart';

class PatchParams {
  final String romPath;
  final String patchPath;
  final String outputPath;
  final bool ignoreChecksum;
  final SendPort sendPort;

  PatchParams({
    required this.romPath,
    required this.patchPath,
    required this.outputPath,
    required this.ignoreChecksum,
    required this.sendPort,
  });
}

class PatchWorker {
  static Future<void> runPatch(PatchParams params) async {
    try {
      final patcher = PatcherFactory.create(
        patchFile: File(params.patchPath),
        romFile: File(params.romPath),
        outputFile: File(params.outputPath),
      );

      final report = await patcher.apply(ignoreChecksum: params.ignoreChecksum);
      params.sendPort.send(PatchResult(
        path: params.outputPath,
        success: true,
        report: report,
      ));
    } catch (e) {
      params.sendPort.send(PatchResult(error: e.toString(), success: false));
    }
  }
}

class PatchResult {
  final bool success;
  final String? path;
  final String? error;

  /// Verification summary for a successful patch (format + integrity checks).
  /// Null on failure.
  final PatchReport? report;

  PatchResult({required this.success, this.path, this.error, this.report});
}
