/// Native file access for lock.json (Android/iOS/desktop).
///
/// Imported ONLY through the conditional import in
/// `local_json_repository.dart` (`if (dart.library.io)`), so this
/// file — and its `dart:io` import — never compiles for web.
///
/// The base directory is the app documents directory
/// (path_provider), or [directoryPath] when the caller supplies one
/// (tests). When the directory cannot be resolved, access falls back
/// to in-memory storage with a plain notice — the app keeps working
/// for the session instead of crashing, and says so.
library;

import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'lock_file_access.dart';

/// Resolves file access for the store. Returns an in-memory access
/// (with a plain notice) when the documents directory cannot be
/// resolved — never throws.
Future<LockFileAccess> createAccess({String? directoryPath}) async {
  try {
    final dir = directoryPath == null
        ? await getApplicationDocumentsDirectory()
        : Directory(directoryPath);
    return _FileLockFileAccess(dir);
  } catch (_) {
    return InMemoryLockFileAccess(
      notice: 'Local file storage is not available on this device — '
          'data is kept in memory only for this session and will be '
          'lost when the app closes.',
    );
  }
}

class _FileLockFileAccess implements LockFileAccess {
  _FileLockFileAccess(this._dir);

  final Directory _dir;

  @override
  bool get isPersistent => true;

  @override
  String? get notice => null;

  File _file(String name) => File('${_dir.path}/$name');

  @override
  Future<String?> readText(String fileName) async {
    final file = _file(fileName);
    if (!await file.exists()) return null;
    return file.readAsString();
  }

  @override
  Future<void> writeAtomic({
    required String fileName,
    required String tmpName,
    required String backupName,
    required List<int> bytes,
  }) async {
    // Recreate the directory if it was removed externally (this
    // VM wipes /tmp without warning; on a real device this is a
    // no-op because the documents directory always exists).
    await _dir.create(recursive: true);
    final target = _file(fileName);
    // Keep the last good state as the backup BEFORE replacing.
    if (await target.exists()) {
      try {
        await target.copy(_file(backupName).path);
      } catch (_) {
        // A stale backup is better than no backup; continue.
      }
    }
    final tmp = _file(tmpName);
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(target.path);
  }

  @override
  Future<void> writeBytes(String relativePath, List<int> bytes) async {
    final file = File('${_dir.path}/$relativePath');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes, flush: true);
  }
}
