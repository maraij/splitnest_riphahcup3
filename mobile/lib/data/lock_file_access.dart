/// File access behind the lock.json store — the seam that keeps
/// `dart:io` out of the store itself, so `flutter build web` still
/// compiles.
///
/// Two implementations exist, chosen by conditional import in
/// `local_json_repository.dart`:
/// - `lock_file_io.dart` (native): real files under the app
///   documents directory.
/// - `lock_file_io_stub.dart` (web): an in-memory map — data does
///   not persist, and [LockFileAccess.notice] says so.
///
/// [InMemoryLockFileAccess] is shared by the stub and by tests.
library;

import 'dart:convert';

/// The file operations the lock.json store needs. [isPersistent]
/// is false when files are only in-memory (web, or a device where
/// the documents directory could not be resolved); [notice] carries
/// the plain in-app message for that case, or null when storage is
/// persistent.
abstract class LockFileAccess {
  bool get isPersistent;
  String? get notice;

  /// File contents as text, or null when the file does not exist.
  Future<String?> readText(String fileName);

  /// Atomic replace of [fileName]: the current contents (when any)
  /// are first copied to [backupName], then [bytes] are written to
  /// [tmpName] (flushed) and renamed over [fileName]. A failure
  /// before the rename leaves the old file untouched.
  Future<void> writeAtomic({
    required String fileName,
    required String tmpName,
    required String backupName,
    required List<int> bytes,
  });

  /// Writes [bytes] to a file below the documents directory
  /// ([relativePath], e.g. `receipts/<gid>/<eid>/receipt.jpg`),
  /// creating parent directories. Used for receipt/profile-photo
  /// bytes only — never for lock.json itself.
  Future<void> writeBytes(String relativePath, List<int> bytes);
}

/// In-memory file access: a map of file name → bytes. Used on web
/// (no documents directory) and in tests. Nothing persists.
class InMemoryLockFileAccess implements LockFileAccess {
  InMemoryLockFileAccess({this.notice});

  final Map<String, List<int>> _files = {};

  @override
  final String? notice;

  @override
  bool get isPersistent => false;

  @override
  Future<String?> readText(String fileName) async {
    final bytes = _files[fileName];
    if (bytes == null) return null;
    return utf8.decode(bytes);
  }

  @override
  Future<void> writeAtomic({
    required String fileName,
    required String tmpName,
    required String backupName,
    required List<int> bytes,
  }) async {
    final current = _files[fileName];
    if (current != null) _files[backupName] = List<int>.of(current);
    _files[tmpName] = List<int>.of(bytes);
    _files[fileName] = _files.remove(tmpName)!;
  }

  @override
  Future<void> writeBytes(String relativePath, List<int> bytes) async {
    _files[relativePath] = List<int>.of(bytes);
  }

  /// Test/read helper: the stored bytes for a path, if any.
  List<int>? bytesFor(String relativePath) => _files[relativePath];
}
