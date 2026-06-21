import 'dart:io';
import 'dart:isolate';
import 'package:final_rom/final_rom.dart';

enum CryptoAction { decrypt, encrypt }

class IsolateParams {
  final CryptoAction action;
  final String inputPath;
  final String? outputPath;
  final String? keysPath;
  final bool inPlace;
  final bool trim;
  final SendPort sendPort;

  IsolateParams({
    required this.action,
    required this.inputPath,
    this.outputPath,
    required this.keysPath,
    required this.inPlace,
    required this.trim,
    required this.sendPort,
  });
}

class CryptoWorker {
  static Future<void> runCrypto(IsolateParams params) async {
    try {
      void progressCallback(CryptoProgress progress) {
        // Send progress directly back to the main isolate.
        params.sendPort.send(progress);
      }

      if (params.keysPath == null || params.keysPath!.isEmpty) {
        throw const FormatException('3DS keys path is not set.');
      }
      final keysContent = await File(params.keysPath!).readAsString();
      final keys = ThreeDsKeys.parse(keysContent);

      String finalPath;
      if (params.action == CryptoAction.decrypt) {
        finalPath = await decrypt3ds(
          params.inputPath,
          keys: keys,
          outputPath: params.outputPath,
          inPlace: params.inPlace,
          trim: params.trim,
          onProgress: progressCallback,
        );
      } else {
        finalPath = await encrypt3ds(
          params.inputPath,
          keys: keys,
          outputPath: params.outputPath,
          inPlace: params.inPlace,
          onProgress: progressCallback,
        );
      }

      params.sendPort.send(CryptoResult(path: finalPath, success: true));
    } catch (e) {
      params.sendPort.send(CryptoResult(error: e.toString(), success: false));
    }
  }
}

class CryptoResult {
  final bool success;
  final String? path;
  final String? error;

  CryptoResult({required this.success, this.path, this.error});
}

