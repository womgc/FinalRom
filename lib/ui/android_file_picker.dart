// This widget is Android-only. Every call site must be guarded with
// `if (Platform.isAndroid)` before invoking any of the static helpers.
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

enum AndroidPickerMode { file, files, directory }

class AndroidFilePicker extends StatefulWidget {
  final List<String> allowedExtensions;
  final AndroidPickerMode mode;

  const AndroidFilePicker({
    super.key,
    required this.allowedExtensions,
    this.mode = AndroidPickerMode.file,
  });

  // ── Static helpers ───────────────────────────────────────────────────────────

  /// Pick a single file. [context] must belong to an Android build.
  static Future<String?> pickFile(
    BuildContext context, {
    List<String> allowedExtensions = const [],
  }) {
    assert(Platform.isAndroid,
        'AndroidFilePicker must only be used on Android.');
    return Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => AndroidFilePicker(
          allowedExtensions: allowedExtensions,
          mode: AndroidPickerMode.file,
        ),
      ),
    );
  }

  /// Pick one or more files. [context] must belong to an Android build.
  static Future<List<String>?> pickFiles(
    BuildContext context, {
    List<String> allowedExtensions = const [],
  }) {
    assert(Platform.isAndroid,
        'AndroidFilePicker must only be used on Android.');
    return Navigator.of(context).push<List<String>>(
      MaterialPageRoute(
        builder: (_) => AndroidFilePicker(
          allowedExtensions: allowedExtensions,
          mode: AndroidPickerMode.files,
        ),
      ),
    );
  }

  /// Pick a directory. [context] must belong to an Android build.
  static Future<String?> pickDirectory(BuildContext context) {
    assert(Platform.isAndroid,
        'AndroidFilePicker must only be used on Android.');
    return Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => const AndroidFilePicker(
          allowedExtensions: [],
          mode: AndroidPickerMode.directory,
        ),
      ),
    );
  }

  @override
  State<AndroidFilePicker> createState() => _AndroidFilePickerState();
}

// ── Storage root discovery ───────────────────────────────────────────────────

/// Represents a top-level storage volume (internal storage or removable media).
class _StorageRoot {
  final String path;
  final String label;
  const _StorageRoot({required this.path, required this.label});
}

/// Returns all storage roots available on this device.
/// Always includes internal storage; also includes any removable volumes
/// (SD card, USB OTG) returned by [getExternalStorageDirectories].
Future<List<_StorageRoot>> _getStorageRoots() async {
  final roots = <_StorageRoot>[];

  // Primary internal storage.
  final internal = Directory('/storage/emulated/0');
  if (await internal.exists()) {
    roots.add(const _StorageRoot(
      path: '/storage/emulated/0',
      label: 'Internal Storage',
    ));
  }

  // Removable volumes (SD card, USB OTG, etc.)
  try {
    final externals = await getExternalStorageDirectories();
    if (externals != null) {
      for (final dir in externals) {
        // getExternalStorageDirectories returns paths like
        // /storage/<UUID>/Android/data/<pkg>/files  →  we want /storage/<UUID>
        var root = dir.path;
        final storageIdx = root.indexOf('/storage/');
        if (storageIdx != -1) {
          final afterStorage = root.substring(storageIdx + '/storage/'.length);
          final slashIdx = afterStorage.indexOf('/');
          final volumeId =
              slashIdx == -1 ? afterStorage : afterStorage.substring(0, slashIdx);
          if (volumeId != 'emulated') {
            root = '/storage/$volumeId';
            final volume = Directory(root);
            if (await volume.exists() && !roots.any((r) => r.path == root)) {
              roots.add(_StorageRoot(
                path: root,
                label: 'Removable Storage ($volumeId)',
              ));
            }
          }
        }
      }
    }
  } catch (_) {
    // Removable volumes are optional; ignore errors.
  }

  return roots;
}

// ── State ────────────────────────────────────────────────────────────────────

class _AndroidFilePickerState extends State<AndroidFilePicker> {
  /// The storage volumes discovered on startup (internal + removable).
  List<_StorageRoot> _storageRoots = [];

  /// The directory currently being browsed. Null means we are at the
  /// "storage roots" overview screen.
  Directory? _currentDirectory;

  List<FileSystemEntity> _entities = [];
  final Set<String> _selectedFiles = {};
  bool _isLoading = true;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _initStorageRoots();
  }

  Future<void> _initStorageRoots() async {
    setState(() => _isLoading = true);
    final roots = await _getStorageRoots();
    if (!mounted) return;
    setState(() {
      _storageRoots = roots;
      _isLoading = false;
    });

    // If only one root exists skip the overview and navigate straight in.
    if (roots.length == 1) {
      _enterDirectory(Directory(roots.first.path));
    }
  }

  /// Navigate into [dir].
  void _enterDirectory(Directory dir) {
    setState(() => _currentDirectory = dir);
    _loadDirectory();
  }

  /// Navigate up one level. If already at a storage root, go back to the
  /// roots overview; if at the overview, pop the route.
  void _navigateUp() {
    if (_currentDirectory == null) {
      Navigator.of(context).pop();
      return;
    }
    final isAtRoot =
        _storageRoots.any((r) => r.path == _currentDirectory!.path);
    if (isAtRoot) {
      if (_storageRoots.length == 1) {
        // Only one root → close the picker.
        Navigator.of(context).pop();
      } else {
        setState(() {
          _currentDirectory = null;
          _entities = [];
          _errorMessage = null;
        });
      }
    } else {
      _enterDirectory(_currentDirectory!.parent);
    }
  }

  Future<void> _loadDirectory() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      final entities = await _currentDirectory!.list().toList();
      entities.sort((a, b) {
        if (a is Directory && b is File) return -1;
        if (a is File && b is Directory) return 1;
        return a.path.toLowerCase().compareTo(b.path.toLowerCase());
      });
      if (!mounted) return;
      setState(() {
        _entities = entities;
        _isLoading = false;
      });
    } on PathAccessException {
      if (!mounted) return;
      setState(() {
        _entities = [];
        _isLoading = false;
        _errorMessage = 'Permission denied — cannot read this folder.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _entities = [];
        _isLoading = false;
        _errorMessage = 'Could not open folder: $e';
      });
    }
  }

  // ── Helpers ─────────────────────────────────────────────────────────────────

  String _buildTitle() {
    if (_currentDirectory == null) return 'Select Storage';
    final path = _currentDirectory!.path;
    final matchedRoot =
        _storageRoots.where((r) => r.path == path).firstOrNull;
    if (matchedRoot != null) return matchedRoot.label;
    return p.basename(path);
  }

  bool _isVisibleFile(FileSystemEntity entity) {
    if (entity is Directory) return true;
    if (widget.allowedExtensions.isEmpty) return true;
    final ext =
        p.extension(entity.path).toLowerCase().replaceAll('.', '');
    return widget.allowedExtensions.contains(ext);
  }

  bool get _canPop {
    if (_currentDirectory == null) return true;
    if (_storageRoots.length == 1 &&
        _currentDirectory!.path == _storageRoots.first.path) {
      return true;
    }
    return false;
  }

  List<Widget>? _buildActions() {
    if (widget.mode != AndroidPickerMode.files || _currentDirectory == null) {
      return null;
    }

    final visibleFiles = _entities
        .where((e) => e is File && _isVisibleFile(e))
        .map((e) => e.path)
        .toList();

    if (visibleFiles.isEmpty) return null;

    final allSelected = visibleFiles.every((path) => _selectedFiles.contains(path));

    return [
      IconButton(
        icon: Icon(allSelected ? Icons.deselect : Icons.select_all),
        tooltip: allSelected ? 'Deselect All' : 'Select All',
        onPressed: () {
          setState(() {
            if (allSelected) {
              for (final path in visibleFiles) {
                _selectedFiles.remove(path);
              }
            } else {
              for (final path in visibleFiles) {
                _selectedFiles.add(path);
              }
            }
          });
        },
      ),
    ];
  }

  // ── Build ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _canPop,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) {
          _navigateUp();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_buildTitle()),
          leading: IconButton(
            icon: const Icon(Icons.arrow_upward),
            tooltip: 'Go up',
            onPressed: _isLoading ? null : _navigateUp,
          ),
          actions: _buildActions(),
        ),
        body: _buildBody(),
        floatingActionButton: _buildFab(),
      ),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    // ── Storage roots overview ────────────────────────────────────────────────
    if (_currentDirectory == null) {
      if (_storageRoots.isEmpty) {
        return const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'No storage volumes found.',
              textAlign: TextAlign.center,
            ),
          ),
        );
      }
      return ListView(
        children: [
          for (final root in _storageRoots)
            ListTile(
              leading: const Icon(Icons.storage),
              title: Text(root.label),
              subtitle: Text(root.path),
              onTap: () => _enterDirectory(Directory(root.path)),
            ),
        ],
      );
    }

    // ── Error state ───────────────────────────────────────────────────────────
    if (_errorMessage != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.lock_outline, size: 48, color: Theme.of(context).colorScheme.error),
              const SizedBox(height: 12),
              Text(
                _errorMessage!,
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    // ── File listing ──────────────────────────────────────────────────────────
    final visible =
        _entities.where(_isVisibleFile).toList();

    if (visible.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.folder_open,
                  size: 48, color: Theme.of(context).colorScheme.onSurfaceVariant),
              const SizedBox(height: 12),
              Text(
                widget.allowedExtensions.isNotEmpty
                    ? 'No ${widget.allowedExtensions.join(' / ').toUpperCase()} files in this folder.'
                    : 'This folder is empty.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      );
    }

    return ListView.builder(
      itemCount: visible.length,
      itemBuilder: (context, index) {
        final entity = visible[index];
        final isDir = entity is Directory;
        final isSelected = _selectedFiles.contains(entity.path);

        return ListTile(
          leading: Icon(isDir ? Icons.folder : Icons.insert_drive_file,
              color: isDir ? Colors.amber.shade700 : null),
          title: Text(p.basename(entity.path)),
          trailing: (widget.mode == AndroidPickerMode.files && !isDir)
              ? Checkbox(
                  value: isSelected,
                  onChanged: (val) => setState(() {
                    if (val == true) {
                      _selectedFiles.add(entity.path);
                    } else {
                      _selectedFiles.remove(entity.path);
                    }
                  }),
                )
              : null,
          onTap: () {
            if (isDir) {
              // ignore: unnecessary_cast
              _enterDirectory(entity as Directory);
            } else {
              if (widget.mode == AndroidPickerMode.file) {
                Navigator.of(context).pop(entity.path);
              } else if (widget.mode == AndroidPickerMode.files) {
                setState(() {
                  if (isSelected) {
                    _selectedFiles.remove(entity.path);
                  } else {
                    _selectedFiles.add(entity.path);
                  }
                });
              }
            }
          },
        );
      },
    );
  }

  Widget? _buildFab() {
    if (widget.mode == AndroidPickerMode.directory &&
        _currentDirectory != null) {
      return FloatingActionButton.extended(
        onPressed: () =>
            Navigator.of(context).pop(_currentDirectory!.path),
        icon: const Icon(Icons.check),
        label: const Text('Select this folder'),
      );
    }
    if (widget.mode == AndroidPickerMode.files &&
        _selectedFiles.isNotEmpty) {
      return FloatingActionButton.extended(
        onPressed: () =>
            Navigator.of(context).pop(_selectedFiles.toList()),
        icon: const Icon(Icons.check),
        label: Text('Select (${_selectedFiles.length})'),
      );
    }
    return null;
  }
}
