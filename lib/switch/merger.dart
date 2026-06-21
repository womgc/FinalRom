import 'pfs0.dart';
import 'xci_reader.dart';

/// Merges a Switch base game with its update and DLC NSPs into a single,
/// installer-compatible `.nsp`.
///
/// This is a **repackaging** merge: it takes the union of all members (NCAs,
/// tickets, certs, and each title's `.cnmt`) across the inputs, de-duplicating
/// by member name. NCA filenames are content-addressed (the file name is a hash
/// of the content), so identical content collapses automatically while every
/// distinct title's content and ticket are preserved. No keys and no decryption
/// are needed.
///
/// Collapsing an update *into* the base program to yield a single merged title
/// is intentionally out of scope — the output holds base + update + DLC content
/// together, which is what installers expect from a "merged" NSP.
class NspMerger {
  /// Merges [inputNspPaths] into [outputPath]. The first path is treated as the
  /// base, the rest as updates/DLC, but ordering only affects which duplicate
  /// member is kept (the first seen).
  static Future<NspMergeResult> merge(
    List<String> inputNspPaths,
    String outputPath, {
    void Function(String message, double fraction)? onProgress,
  }) async {
    if (inputNspPaths.length < 2) {
      throw ArgumentError('Merging needs at least two NSP inputs.');
    }

    final builder = Pfs0Builder();
    final seenNames = <String>{};
    var addedMembers = 0;

    for (var fileIndex = 0; fileIndex < inputNspPaths.length; fileIndex++) {
      final path = inputNspPaths[fileIndex];
      final filename = path.split(RegExp(r"[\\/]")).last;
      // Collecting entries only reads headers, so it is near-instant; the
      // real work (and the progress bar) belongs to the data copy below.
      onProgress?.call('Reading $filename', 0);

      final isXci = path.toLowerCase().endsWith('.xci');
      if (isXci) {
        final reader = await XciReader.open(path);
        try {
          for (final entry in reader.entries) {
            if (!seenNames.add(entry.name)) continue; // duplicate; keep the first
            builder.add(Pfs0Member.fromFile(
              entry.name,
              path,
              size: entry.size,
              sourceOffset: entry.offset,
            ));
            addedMembers++;
          }
        } finally {
          await reader.close();
        }
      } else {
        final reader = await Pfs0Reader.open(path);
        try {
          for (final entry in reader.entries) {
            if (!seenNames.add(entry.name)) continue; // duplicate; keep the first
            builder.add(Pfs0Member.fromFile(
              entry.name,
              path,
              size: entry.dataSize,
              sourceOffset: entry.dataOffset,
            ));
            addedMembers++;
          }
        } finally {
          await reader.close();
        }
      }
    }

    var lastReportedPercent = -1;
    await builder.writeTo(
      outputPath,
      onProgress: (bytesWritten, totalBytes) {
        if (onProgress == null || totalBytes == 0) return;
        final fraction = bytesWritten / totalBytes;
        final percent = (fraction * 100).floor();
        // Throttle to whole-percent steps so we don't flood the isolate port.
        if (percent == lastReportedPercent) return;
        lastReportedPercent = percent;
        final writtenGb = bytesWritten / (1024 * 1024 * 1024);
        final totalGb = totalBytes / (1024 * 1024 * 1024);
        onProgress(
          'Writing merged NSP '
          '(${writtenGb.toStringAsFixed(2)} / ${totalGb.toStringAsFixed(2)} GB)',
          fraction,
        );
      },
    );
    onProgress?.call('Done', 1.0);

    return NspMergeResult(
      outputPath: outputPath,
      memberCount: addedMembers,
      sourceCount: inputNspPaths.length,
    );
  }
}

class NspMergeResult {
  final String outputPath;
  final int memberCount;
  final int sourceCount;

  NspMergeResult({
    required this.outputPath,
    required this.memberCount,
    required this.sourceCount,
  });
}
