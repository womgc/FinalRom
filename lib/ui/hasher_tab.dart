import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:path/path.dart' as p;
import 'package:final_rom/l10n/app_localizations.dart';

import '../blocs/hasher_bloc.dart';
import '../services/file_service.dart';
import 'home_screen.dart'; // For DragDropTarget
import 'android_file_picker.dart';
import 'app_spacing.dart';
import 'theme.dart';
import 'dart:io';

class HasherTab extends StatefulWidget {
  const HasherTab({super.key});
  @override
  State<HasherTab> createState() => _HasherTabState();
}

class _HasherTabState extends State<HasherTab> {
  String? _selectedFile;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    return DragDropTarget(
      hintText: loc.dragDropHintHash,
      onFilesDropped: (paths) {
        if (paths.isNotEmpty) {
          setState(() => _selectedFile = paths.first);
          context.read<HasherBloc>().add(StartHashing(paths.first));
        }
      },
      child: BlocConsumer<HasherBloc, HasherState>(
        listener: (context, state) {
          if (state is HasherFailure) {
            showErrorSnackBar(context, state.error);
          }
        },
        builder: (context, state) {
          final isRunning = state is HasherRunning;
          return Padding(
            padding: AppSpacing.page,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Card(
                  child: Padding(
                    padding: AppSpacing.card,
                    child: Column(
                      children: [
                        Text(loc.fileToHash, style: Theme.of(context).textTheme.titleSmall),
                        Text(
                          _selectedFile != null
                              ? p.basename(_selectedFile!)
                              : loc.errNoFileSelected,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        AppSpacing.gapSm,
                        FilledButton.icon(
                          icon: const Icon(Icons.folder_open),
                          label: Text(loc.btnBrowse),
                          onPressed: isRunning
                              ? null
                              : () async {
                                  String? file;
                                  if (Platform.isAndroid && context.mounted) {
                                    file = await AndroidFilePicker.pickFile(context);
                                  } else {
                                    file = await FileService.pickAnyFile();
                                  }
                                  if (file != null) {
                                    setState(() => _selectedFile = file);
                                    if (context.mounted) {
                                      context.read<HasherBloc>().add(StartHashing(file));
                                    }
                                  }
                                },
                        ),
                      ],
                    ),
                  ),
                ),
                AppSpacing.gapLg,
                if (isRunning) ...[
                  const LinearProgressIndicator(),
                  AppSpacing.gapSm,
                  Text(
                    loc.statusHashing,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  AppSpacing.gapLg,
                ] else if (state is HasherSuccess) ...[
                  Expanded(
                    child: ListView(
                      children: [
                        _buildHashTile(context, 'CRC32', state.result.crc32Hash),
                        _buildHashTile(context, 'MD5', state.result.md5Hash),
                        _buildHashTile(context, 'SHA-1', state.result.sha1Hash),
                        _buildHashTile(context, 'SHA-256', state.result.sha256Hash),
                      ],
                    ),
                  ),
                ],

                if (isRunning)
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: Theme.of(context).colorScheme.error,
                      foregroundColor: Theme.of(context).colorScheme.onError,
                    ),
                    onPressed: () => context.read<HasherBloc>().add(CancelHashing()),
                    child: Text(loc.btnCancel),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildHashTile(BuildContext context, String title, String? hash) {
    final loc = AppLocalizations.of(context)!;
    return Card(
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: ListTile(
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
        subtitle: Text(hash ?? 'N/A', style: context.monospace),
        trailing: IconButton(
          icon: const Icon(Icons.copy),
          onPressed: hash != null
              ? () {
                  Clipboard.setData(ClipboardData(text: hash));
                  showInfoSnackBar(context, loc.copiedToClipboard(title));
                }
              : null,
        ),
      ),
    );
  }
}
