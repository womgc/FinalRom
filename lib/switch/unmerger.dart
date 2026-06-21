import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'cnmt.dart';
import 'keys.dart';
import 'nca.dart';
import 'pfs0.dart';

/// One title (base/update/DLC) recovered from a merged NSP's CNMT metadata.
class TitleGroup {
  final int titleId;
  final int version;
  final ContentMetaType metaType;
  final List<Pfs0Entry> memberEntries;
  final List<String> missingNcaIds;
  final String? rightsIdHex;

  TitleGroup({
    required this.titleId,
    required this.version,
    required this.metaType,
    required this.memberEntries,
    required this.missingNcaIds,
    required this.rightsIdHex,
  });

  String get outputBaseName {
    final titleIdHex = titleId.toRadixString(16).padLeft(16, '0');
    final label = switch (metaType) {
      ContentMetaType.application => 'base',
      ContentMetaType.patch => 'update',
      ContentMetaType.addOnContent => 'dlc',
      _ => metaType.name,
    };
    return '${titleIdHex}_${label}_v$version';
  }
}

class UnmergedTitleResult {
  final String outputPath;
  final int titleId;
  final ContentMetaType metaType;
  final List<String> missingNcaIds;

  UnmergedTitleResult({
    required this.outputPath,
    required this.titleId,
    required this.metaType,
    required this.missingNcaIds,
  });
}

class NspUnmergeResult {
  final List<UnmergedTitleResult> outputs;
  final String sourcePath;

  NspUnmergeResult({required this.outputs, required this.sourcePath});
}

/// Splits a merged NSP (base + update + DLC content unioned together, as
/// produced by [NspMerger]) back into one `.nsp` per title, by parsing each
/// embedded CNMT to learn which NCAs belong to which title.
class NspUnmerger {
  static Future<NspUnmergeResult> unmerge(
    String inputNspPath,
    String outputDir, {
    required SwitchKeys keys,
    void Function(String message, double fraction)? onProgress,
  }) async {
    final reader = await Pfs0Reader.open(inputNspPath);
    try {
      final ncaEntries = <String, Pfs0Entry>{}; // filename stem -> entry
      final cnmtXmlEntries = <String, Pfs0Entry>{}; // filename stem -> entry
      final ticketEntries = <Pfs0Entry>[];
      final certEntries = <Pfs0Entry>[];
      for (final entry in reader.entries) {
        final lower = entry.name.toLowerCase();
        if (lower.endsWith('.nca')) {
          ncaEntries[_stem(entry.name)] = entry;
        } else if (lower.endsWith('.cnmt.xml')) {
          cnmtXmlEntries[_stem(entry.name)] = entry;
        } else if (lower.endsWith('.tik')) {
          ticketEntries.add(entry);
        } else if (lower.endsWith('.cert')) {
          certEntries.add(entry);
        }
      }

      final ticketEntriesByRightsId =
          await _loadTicketEntries(reader, ticketEntries);
      final ticketsByRightsId = ticketEntriesByRightsId.map(
        (rightsIdHex, entryAndTicket) =>
            MapEntry(rightsIdHex, entryAndTicket.$2),
      );

      onProgress?.call('Reading NCA headers', 0);
      final parsedByEntry = <Pfs0Entry, Nca>{};
      for (final entry in ncaEntries.values) {
        final rawHeader = await reader.readEntry(
          entry,
          length: Nca.headerEncryptedRegion,
        );
        final nca = Nca.parse(
          rawHeader,
          keys,
          resolveTicket: (rightsId) => ticketsByRightsId[_hex(rightsId)],
        );
        parsedByEntry[entry] = nca;
      }

      final metaEntries = parsedByEntry.entries
          .where((e) => e.value.contentType == NcaContentType.meta)
          .toList();
      if (metaEntries.isEmpty) {
        throw const FormatException(
            'No meta (.cnmt) NCA found — is this a valid merged NSP?');
      }

      final titleGroups = <TitleGroup>[];
      for (var i = 0; i < metaEntries.length; i++) {
        final metaEntry = metaEntries[i].key;
        final metaNca = metaEntries[i].value;
        onProgress?.call('Parsing CNMT ${i + 1}/${metaEntries.length}',
            i / metaEntries.length);

        final section = metaNca.sections.single;
        final rawBody = await reader.readEntry(
          metaEntry,
          offsetInEntry: section.offset,
          length: section.size,
        );
        final sectionBody = section.crypto == NcaSectionCrypto.none
            ? rawBody
            : section.cipherAtStart().process(rawBody);
        // The section body is a hashed PFS0 partition (master hash + PFS0),
        // not the raw CNMT bytes; unwrap it to get the actual .cnmt file.
        final innerPfs0 = Uint8List.sublistView(
          sectionBody,
          section.pfs0Offset,
          section.pfs0Offset + section.pfs0Size,
        );
        final cnmtFiles = parsePfs0Bytes(innerPfs0);
        if (cnmtFiles.isEmpty) {
          throw const FormatException('Meta NCA PFS0 contains no .cnmt file.');
        }
        final meta = ContentMeta.parse(cnmtFiles.first);

        final memberEntries = <Pfs0Entry>[metaEntry];
        final cnmtXmlEntry = cnmtXmlEntries[_stem(metaEntry.name)];
        if (cnmtXmlEntry != null) memberEntries.add(cnmtXmlEntry);
        final missing = <String>[];
        for (final content in meta.contentEntries) {
          // Meta is the CNMT's self-reference (already added above).
          // DeltaFragment entries are Nintendo's binary-diff distribution
          // mechanism — they don't correspond to any physically installed
          // NCA in a standard repacked NSP, so they're never "missing".
          if (content.type == ContentEntryType.meta ||
              content.type == ContentEntryType.deltaFragment) {
            continue;
          }
          final refEntry = ncaEntries[content.ncaIdHex];
          if (refEntry == null) {
            missing.add(content.ncaIdHex);
            continue;
          }
          memberEntries.add(refEntry);
        }

        String? rightsIdHex;
        for (final entry in memberEntries) {
          final nca = parsedByEntry[entry];
          if (nca != null && nca.rightsId.any((b) => b != 0)) {
            rightsIdHex = _hex(nca.rightsId);
            break;
          }
        }

        titleGroups.add(TitleGroup(
          titleId: meta.titleId,
          version: meta.version,
          metaType: meta.metaType,
          memberEntries: memberEntries,
          missingNcaIds: missing,
          rightsIdHex: rightsIdHex,
        ));
      }

      final results = <UnmergedTitleResult>[];
      for (var i = 0; i < titleGroups.length; i++) {
        final group = titleGroups[i];
        final builder = Pfs0Builder();
        for (final entry in group.memberEntries) {
          builder.add(Pfs0Member.fromFile(
            entry.name,
            inputNspPath,
            size: entry.dataSize,
            sourceOffset: entry.dataOffset,
          ));
        }
        if (group.rightsIdHex != null) {
          final tikEntry = ticketEntriesByRightsId[group.rightsIdHex]?.$1;
          if (tikEntry != null) {
            builder.add(Pfs0Member.fromFile(
              tikEntry.name,
              inputNspPath,
              size: tikEntry.dataSize,
              sourceOffset: tikEntry.dataOffset,
            ));
            // The cert shares the ticket's filename stem (same hex base, a
            // different extension) — match by stem rather than including
            // every cert in the merged NSP, since each title has its own.
            final tikStem = _stem(tikEntry.name);
            for (final certEntry in certEntries) {
              if (_stem(certEntry.name) == tikStem) {
                builder.add(Pfs0Member.fromFile(
                  certEntry.name,
                  inputNspPath,
                  size: certEntry.dataSize,
                  sourceOffset: certEntry.dataOffset,
                ));
              }
            }
          }
        }

        final outputPath = p.join(outputDir, '${group.outputBaseName}.nsp');
        await builder.writeTo(
          outputPath,
          onProgress: (bytesWritten, totalBytes) {
            if (onProgress == null || totalBytes == 0) return;
            final fraction = (i + bytesWritten / totalBytes) / titleGroups.length;
            onProgress('Writing ${group.outputBaseName}.nsp', fraction);
          },
        );

        results.add(UnmergedTitleResult(
          outputPath: outputPath,
          titleId: group.titleId,
          metaType: group.metaType,
          missingNcaIds: group.missingNcaIds,
        ));
      }

      onProgress?.call('Done', 1.0);
      return NspUnmergeResult(outputs: results, sourcePath: inputNspPath);
    } finally {
      await reader.close();
    }
  }

  /// Parses every `.tik` entry and indexes both the raw [Pfs0Entry] (for
  /// verbatim copying into a split output) and the parsed [SwitchTicket]
  /// (for [Nca.parse]'s titlekey decryption) by hex rights ID.
  static Future<Map<String, (Pfs0Entry, SwitchTicket)>> _loadTicketEntries(
    Pfs0Reader reader,
    List<Pfs0Entry> ticketEntries,
  ) async {
    final tickets = <String, (Pfs0Entry, SwitchTicket)>{};
    for (final entry in ticketEntries) {
      final bytes = await reader.readEntry(entry);
      try {
        final ticket = SwitchTicket.parse(bytes);
        tickets[_hex(ticket.rightsId)] = (entry, ticket);
      } on SwitchKeysException {
        // Skip malformed tickets; titlekey NCAs needing them will surface a
        // clear error during Nca.parse.
      }
    }
    return tickets;
  }

  static String _stem(String filename) {
    final dot = filename.lastIndexOf('.');
    return dot == -1 ? filename : filename.substring(0, dot);
  }

  static String _hex(Uint8List bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}
