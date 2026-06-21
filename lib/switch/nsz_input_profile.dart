import '../settings/performance_preset.dart';
import 'pfs0.dart';

/// Builds an [InputProfile] for an NSP by peeking its PFS0 header — counts the
/// compressible NCAs and measures how dominant the largest one is, so the
/// performance-preset resolver can decide whether per-NCA parallelism can help.
///
/// Header-only: no file body is read. Returns a dominant-NCA profile on any
/// error so the resolver stays conservative (caps concurrency to 1).
Future<InputProfile> buildNspInputProfile(String nspPath) async {
  /// NCAs at or below this size (PFS0 header/metadata, .cnmt) are not worth
  /// compressing and are ignored when judging dominance. Mirrors the threshold
  /// in NszArchive (0x4000).
  const minCompressibleNca = 0x4000;
  try {
    final reader = await Pfs0Reader.open(nspPath);
    try {
      final ncaSizes = reader.entries
          .where((entry) =>
              entry.name.toLowerCase().endsWith('.nca') &&
              entry.dataSize > minCompressibleNca)
          .map((entry) => entry.dataSize)
          .toList();
      final total = ncaSizes.fold<int>(0, (sum, size) => sum + size);
      final largest =
          ncaSizes.isEmpty ? 0 : ncaSizes.reduce((a, b) => a > b ? a : b);
      return InputProfile(
        totalBytes: total,
        compressibleNcaCount: ncaSizes.length,
        largestNcaFraction: total == 0 ? 1.0 : largest / total,
      );
    } finally {
      await reader.close();
    }
  } catch (_) {
    return const InputProfile(
        totalBytes: 0, compressibleNcaCount: 1, largestNcaFraction: 1.0);
  }
}
