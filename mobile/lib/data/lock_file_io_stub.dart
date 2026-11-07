/// Web file access for lock.json — the conditional-import stub.
///
/// `dart:io` does not exist on web, so this file is what
/// `local_json_repository.dart` imports there: an in-memory store
/// with a plain notice that web preview data does not persist.
/// Nothing here ever touches the network or any cloud service.
library;

import 'lock_file_access.dart';

/// Web preview: in-memory only, always. [directoryPath] is ignored.
Future<LockFileAccess> createAccess({String? directoryPath}) async =>
    InMemoryLockFileAccess(
      notice: 'Web preview: data is kept in memory only and does not '
          'persist — reload the page and the household starts fresh.',
    );
