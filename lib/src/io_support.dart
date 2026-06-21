import 'dart:io';

import 'package:path/path.dart' as p;

/// Bytes of an ASCII magic string (e.g. `NCSD`, `NCCH`).
List<int> asciiBytes(String value) => value.codeUnits;

/// Whether the first [length] bytes of [data] equal [expected]'s ASCII bytes.
bool magicEquals(List<int> data, String expected) {
  final want = asciiBytes(expected);
  if (data.length < want.length) return false;
  for (var i = 0; i < want.length; i++) {
    if (data[i] != want[i]) return false;
  }
  return true;
}

/// Compare [a] against [b] over [length] bytes.
bool bytesEqual(List<int> a, List<int> b, int length) {
  if (a.length < length || b.length < length) return false;
  for (var i = 0; i < length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Resolve where the converter should write.
///
/// When [inPlace] is true the original file is edited directly. Otherwise the
/// original is copied to [outputPath] (or a name derived from [inputPath] with
/// [suffix], e.g. `game-decrypted.3ds`) and that copy is returned so the
/// original stays untouched.
Future<String> resolveTarget(
  String inputPath,
  String? outputPath,
  bool inPlace,
  String suffix,
) async {
  if (inPlace) return inputPath;
  var target = outputPath ?? deriveOutputPath(inputPath, suffix);
  // Batch mode passes an output *folder* as [outputPath]; place the derived
  // filename inside it rather than copying onto the directory itself, which
  // fails with EISDIR (errno 21) on Android.
  if (await FileSystemEntity.isDirectory(target)) {
    target = p.join(target, p.basename(deriveOutputPath(inputPath, suffix)));
  }
  await File(inputPath).copy(target);
  return target;
}

/// Insert [suffix] before the extension: `dir/game.3ds` -> `dir/game-suffix.3ds`.
String deriveOutputPath(String inputPath, String suffix) {
  final lastSep = inputPath.lastIndexOf(RegExp(r'[\\/]'));
  final lastDot = inputPath.lastIndexOf('.');
  if (lastDot > lastSep) {
    return '${inputPath.substring(0, lastDot)}-$suffix${inputPath.substring(lastDot)}';
  }
  return '$inputPath-$suffix';
}
