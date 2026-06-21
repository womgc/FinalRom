import 'dart:io';
import 'package:xdelta3_ffi/xdelta3_ffi.dart';
import 'patcher.dart';

/// xdelta3 / VCDIFF patcher. Delegates to the native xdelta3 library through
/// the `xdelta3_ffi` plugin. Ported from UniPatcher's `XDelta.kt`.
///
/// The native call is synchronous and blocking, which is fine because patching
/// already runs inside a background isolate.
class XdeltaPatcher extends RomPatcher {
  XdeltaPatcher({
    required super.patchFile,
    required super.romFile,
    required super.outputFile,
  });

  /// Legacy XDelta1 magic strings — these are not supported by xdelta3.
  static const List<String> _xdelta1Magics = [
    '%XDELTA%',
    '%XDZ000%',
    '%XDZ001%',
    '%XDZ002%',
    '%XDZ003%',
    '%XDZ004%',
  ];

  @override
  Future<PatchReport> apply({bool ignoreChecksum = false}) async {
    if (await _isXdelta1()) {
      throw PatchException("XDelta1 patches are not supported.");
    }

    int result;
    try {
      result = xdelta3Apply(
        patchFile.path,
        romFile.path,
        outputFile.path,
        ignoreChecksum: ignoreChecksum,
      );
    } catch (error) {
      throw PatchException(
          "Failed to load the native xdelta3 library: $error");
    }

    switch (result) {
      case XdeltaResult.ok:
        // xdelta3 verifies the VCDIFF source/output checksums internally.
        return PatchReport(format: "xdelta", checks: [
          PatchCheck("VCDIFF integrity",
              ignoreChecksum ? CheckOutcome.skipped : CheckOutcome.passed),
        ]);
      case XdeltaResult.errOpenPatch:
        throw PatchException("Unable to open the patch file.");
      case XdeltaResult.errOpenRom:
        throw PatchException("Unable to open the ROM file.");
      case XdeltaResult.errOpenOutput:
        throw PatchException("Unable to open the output file.");
      case XdeltaResult.errWrongChecksum:
        throw PatchException("ROM is not compatible with this patch.");
      case XdeltaResult.errLibUnavailable:
        throw PatchException(
            "The native xdelta3 library could not be loaded on this device.");
      default:
        throw PatchException("xdelta3 failed with error code $result.");
    }
  }

  Future<bool> _isXdelta1() async {
    final raf = await patchFile.open(mode: FileMode.read);
    try {
      final magic = await raf.read(8);
      if (magic.length < 8) return false;
      final asString = String.fromCharCodes(magic);
      return _xdelta1Magics.contains(asString);
    } finally {
      await raf.close();
    }
  }
}
