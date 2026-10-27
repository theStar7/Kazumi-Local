import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:hive_ce/hive.dart';
import 'package:kazumi/modules/local_video/local_video.dart';
import 'package:kazumi/modules/local_video/local_video_folder.dart';
import 'package:path/path.dart' as path;

class LocalVideoImportResult {
  const LocalVideoImportResult({
    required this.added,
    required this.failedPaths,
    this.duplicateCount = 0,
    this.unsupportedCount = 0,
  });

  final List<LocalVideo> added;
  final List<String> failedPaths;
  final int duplicateCount;
  final int unsupportedCount;
}

class LocalVideoRepository {
  LocalVideoRepository(this._box, {Box<String>? foldersBox})
    : _foldersBox = foldersBox;

  final Box<String> _box;
  final Box<String>? _foldersBox;
  Future<void>? _layoutInitialization;

  static const _rootFolderId = '__local_video_library_root_v1__';

  static const _extensions = {
    '.mp4',
    '.mkv',
    '.avi',
    '.mov',
    '.webm',
    '.flv',
    '.wmv',
    '.m4v',
    '.ts',
    '.m2ts',
    '.mpg',
    '.mpeg',
  };

  List<LocalVideo> get videos => _box.values
      .map(
        (value) =>
            LocalVideo.fromJson(jsonDecode(value) as Map<String, dynamic>),
      )
      .toList();

  List<LocalVideoFolder> get folders => (_foldersBox?.values ?? <String>[])
      .map(
        (value) => LocalVideoFolder.fromJson(
          jsonDecode(value) as Map<String, dynamic>,
        ),
      )
      .where((folder) => folder.id != _rootFolderId)
      .toList();

  LocalVideo? findById(String id) {
    final value = _box.get(id);
    return value == null
        ? null
        : LocalVideo.fromJson(jsonDecode(value) as Map<String, dynamic>);
  }

  LocalVideoFolder? findFolderById(String id) {
    if (id == _rootFolderId) {
      return null;
    }
    final value = _foldersBox?.get(id);
    return value == null
        ? null
        : LocalVideoFolder.fromJson(jsonDecode(value) as Map<String, dynamic>);
  }

  LocalVideoFolder? get _rootFolder {
    final value = _foldersBox?.get(_rootFolderId);
    return value == null
        ? null
        : LocalVideoFolder.fromJson(jsonDecode(value) as Map<String, dynamic>);
  }

  Future<void> initializeLibraryLayout() async {
    final pending = _layoutInitialization;
    if (pending != null) {
      return pending;
    }
    if (_foldersBox == null || _rootFolder != null) {
      return;
    }
    final initialization = _migrateLibraryLayout();
    _layoutInitialization = initialization;
    try {
      await initialization;
    } finally {
      _layoutInitialization = null;
    }
  }

  Future<void> _migrateLibraryLayout() async {
    final allVideos = videos;
    final diskFolders = folders.where((folder) => folder.isDisk).toList();
    final diskVideoIds = <String>{};
    for (final folder in diskFolders) {
      final directIds = allVideos
          .where(
            (video) =>
                _pathIdentity(path.dirname(video.path)) ==
                _pathIdentity(folder.directoryPath!),
          )
          .map((video) => video.id);
      diskVideoIds.addAll(directIds);
      await _putFolder(
        folder.copyWith(
          videoIds: {...folder.videoIds, ...directIds}.toList(),
          sourceVideoIds: {
            ...folder.sourceVideoIds,
            ...folder.videoIds,
            ...directIds,
          }.toList(),
        ),
      );
    }
    // This record is also the completion marker, so persist it last.
    await _putFolder(
      LocalVideoFolder(
        id: _rootFolderId,
        name: '',
        type: LocalVideoFolderType.virtual,
        videoIds: allVideos
            .where((video) => !diskVideoIds.contains(video.id))
            .map((video) => video.id)
            .toList(),
      ),
    );
  }

  List<LocalVideoFolder> foldersIn(String? parentId) =>
      folders.where((folder) => folder.parentId == parentId).toList()
        ..sort((a, b) => _compareNames(a.name, b.name));

  List<LocalVideo> videosIn(String? folderId) {
    final allVideos = videos;
    final root = _rootFolder;
    if (root != null) {
      final references = folderId == null
          ? root.videoIds
          : findFolderById(folderId)?.videoIds ?? <String>[];
      return allVideos.where((video) => references.contains(video.id)).toList()
        ..sort(_compareVideos);
    }
    if (folderId == null) {
      final diskFolders = folders.where((folder) => folder.isDisk).toList();
      return allVideos
          .where(
            (video) => !diskFolders.any(
              (folder) =>
                  _pathIdentity(folder.directoryPath!) ==
                  _pathIdentity(path.dirname(video.path)),
            ),
          )
          .toList()
        ..sort(_compareVideos);
    }
    final folder = findFolderById(folderId);
    if (folder == null) {
      return [];
    }
    return allVideos
        .where(
          (video) => folder.isVirtual
              ? folder.videoIds.contains(video.id)
              : _pathIdentity(path.dirname(video.path)) ==
                    _pathIdentity(folder.directoryPath!),
        )
        .toList()
      ..sort(_compareVideos);
  }

  List<LocalVideo> playlistInFolder(String id, {String? folderId}) {
    final playlist = videosIn(folderId);
    return playlist.any((video) => video.id == id) ? playlist : [];
  }

  List<LocalVideo> playlistFor(String id) {
    final current = findById(id);
    if (current == null) {
      return [];
    }
    final directory = _pathIdentity(path.dirname(current.path));
    return videos
        .where((video) => _pathIdentity(path.dirname(video.path)) == directory)
        .toList()
      ..sort(_compareVideos);
  }

  Future<LocalVideoFolder> createVirtualFolder(
    String name, {
    String? parentId,
  }) async {
    _requireFoldersBox();
    await initializeLibraryLayout();
    _validateParent(parentId);
    final random = Random.secure();
    final folder = LocalVideoFolder(
      id: sha256
          .convert(List.generate(32, (_) => random.nextInt(256)))
          .toString(),
      name: _folderName(name),
      type: LocalVideoFolderType.virtual,
      parentId: parentId,
    );
    await _putFolder(folder);
    return folder;
  }

  Future<void> renameFolder(String id, String name) async {
    await initializeLibraryLayout();
    final folder = _folder(id);
    await _putFolder(folder.copyWith(name: _folderName(name)));
  }

  Future<void> addVideosToFolder(
    String folderId,
    Iterable<String> videoIds,
  ) async {
    await initializeLibraryLayout();
    _folder(folderId);
    final ids = videoIds.toSet();
    for (final id in ids) {
      if (findById(id) == null) {
        throw ArgumentError.value(id, 'videoIds', 'Video does not exist');
      }
    }
    await _addReferences(folderId, ids);
  }

  Future<void> _addReferences(
    String? folderId,
    Iterable<String> videoIds,
  ) async {
    final folder = _membershipFolder(folderId);
    final addedIds = videoIds.toSet();
    final references = {...folder.videoIds, ...addedIds};
    final sourceIds = {
      ...folder.sourceVideoIds,
      if (folder.isDisk) ...addedIds,
    };
    if (references.length != folder.videoIds.length ||
        sourceIds.length != folder.sourceVideoIds.length) {
      await _putFolder(
        folder.copyWith(
          videoIds: references.toList(),
          sourceVideoIds: sourceIds.toList(),
        ),
      );
    }
  }

  Future<void> _addSourceReference(
    String folderId,
    String videoId, {
    required bool isNewRecord,
  }) async {
    final folder = _folder(folderId);
    if (!isNewRecord && folder.sourceVideoIds.contains(videoId)) {
      return;
    }
    await _putFolder(
      folder.copyWith(
        videoIds: {...folder.videoIds, videoId}.toList(),
        sourceVideoIds: {...folder.sourceVideoIds, videoId}.toList(),
      ),
    );
  }

  Future<void> removeVideoFromFolder(String folderId, String videoId) async {
    await initializeLibraryLayout();
    final folder = _folder(folderId);
    if (!folder.videoIds.contains(videoId)) {
      return;
    }
    await _returnOrphansToRoot([videoId], excludingFolders: {folderId});
    await _putFolder(
      folder.copyWith(
        videoIds: folder.videoIds.where((id) => id != videoId).toList(),
      ),
    );
  }

  Future<void> removeFolder(String id) async {
    final box = _requireFoldersBox();
    await initializeLibraryLayout();
    _folder(id);
    final allFolders = folders;
    final removedIds = <String>{id};
    var previousSize = 0;
    while (removedIds.length != previousSize) {
      previousSize = removedIds.length;
      removedIds.addAll(
        allFolders
            .where((folder) => removedIds.contains(folder.parentId))
            .map((folder) => folder.id),
      );
    }
    await _returnOrphansToRoot(
      allFolders
          .where((folder) => removedIds.contains(folder.id))
          .expand((folder) => folder.videoIds),
      excludingFolders: removedIds,
    );
    await box.deleteAll(removedIds);
  }

  Future<void> _returnOrphansToRoot(
    Iterable<String> candidates, {
    required Set<String> excludingFolders,
  }) async {
    final remainingIds = folders
        .where((folder) => !excludingFolders.contains(folder.id))
        .expand((folder) => folder.videoIds)
        .toSet();
    final orphanIds = candidates
        .where((id) => !remainingIds.contains(id) && findById(id) != null)
        .toSet();
    if (orphanIds.isNotEmpty) {
      await _addReferences(null, orphanIds);
    }
  }

  Future<void> moveVideo(
    String videoId, {
    String? fromFolderId,
    String? toFolderId,
  }) async {
    _requireFoldersBox();
    await initializeLibraryLayout();
    if (findById(videoId) == null) {
      throw ArgumentError.value(videoId, 'videoId', 'Video does not exist');
    }
    final source = _membershipFolder(fromFolderId);
    _membershipFolder(toFolderId);
    if (!source.videoIds.contains(videoId)) {
      throw ArgumentError.value(
        videoId,
        'videoId',
        'Video is not in the source folder',
      );
    }
    if (fromFolderId == toFolderId) {
      return;
    }
    // Keep the source reference until the target has been persisted.
    await _addReferences(toFolderId, [videoId]);
    await _putFolder(
      source.copyWith(
        videoIds: source.videoIds.where((id) => id != videoId).toList(),
      ),
    );
  }

  bool canMoveFolder(String folderId, String? targetParentId) {
    final folder = findFolderById(folderId);
    if (folder == null || folder.parentId == targetParentId) {
      return false;
    }
    var current = targetParentId;
    final visited = <String>{};
    while (current != null) {
      if (current == folderId || !visited.add(current)) {
        return false;
      }
      final parent = findFolderById(current);
      if (parent == null) {
        return false;
      }
      current = parent.parentId;
    }
    return true;
  }

  Future<void> moveFolder(String folderId, String? targetParentId) async {
    await initializeLibraryLayout();
    final folder = _folder(folderId);
    _validateParent(targetParentId);
    if (folder.parentId == targetParentId) {
      return;
    }
    if (!canMoveFolder(folderId, targetParentId)) {
      throw ArgumentError.value(
        targetParentId,
        'targetParentId',
        'Cannot move a folder into itself or a descendant',
      );
    }
    await _putFolder(folder.copyWith(parentId: targetParentId));
  }

  Future<LocalVideoImportResult> importFiles(
    Iterable<String> paths, {
    String? folderId,
  }) async {
    await initializeLibraryLayout();
    return _importFiles(paths, folderId: folderId);
  }

  Future<LocalVideoImportResult> _importFiles(
    Iterable<String> paths, {
    String? folderId,
    bool sourceImport = false,
  }) async {
    if (folderId != null) {
      _folder(folderId);
    }
    final added = <LocalVideo>[];
    final failedPaths = <String>[];
    var duplicateCount = 0;
    var unsupportedCount = 0;
    for (final input in paths) {
      final absolutePath = path.normalize(path.absolute(input));
      if (!_extensions.contains(path.extension(absolutePath).toLowerCase())) {
        unsupportedCount++;
        continue;
      }
      try {
        final file = await File(absolutePath).open(mode: FileMode.read);
        await file.close();
      } on FileSystemException {
        failedPaths.add(absolutePath);
        continue;
      }

      final id = sha256
          .convert(utf8.encode(_pathIdentity(absolutePath)))
          .toString();
      final exists = _box.containsKey(id);
      // Keep source history and membership in the same write, before storing
      // a new video, so retries can recover only the unfinished references.
      if (_foldersBox != null) {
        if (sourceImport) {
          await _addSourceReference(folderId!, id, isNewRecord: !exists);
        } else {
          await _addReferences(folderId, [id]);
        }
      }
      if (exists) {
        duplicateCount++;
        continue;
      }
      final video = LocalVideo(
        id: id,
        path: absolutePath,
        name: path.basename(absolutePath),
      );
      await _box.put(id, jsonEncode(video.toJson()));
      added.add(video);
    }
    return LocalVideoImportResult(
      added: added,
      failedPaths: failedPaths,
      duplicateCount: duplicateCount,
      unsupportedCount: unsupportedCount,
    );
  }

  Future<LocalVideoImportResult> importDirectory(
    String directory, {
    String? parentId,
  }) async {
    _requireFoldersBox();
    await initializeLibraryLayout();
    _validateParent(parentId);
    final rootPath = path.normalize(path.absolute(directory));
    final added = <LocalVideo>[];
    final failedPaths = <String>[];
    var duplicateCount = 0;
    var unsupportedCount = 0;

    Future<void> scan(Directory current, String? parentId) async {
      final folder = await _registerDiskFolder(
        current.path,
        parentId: parentId,
      );
      final directPaths = <String>[];
      try {
        await for (final entity in current.list(followLinks: false)) {
          if (entity is Directory) {
            await scan(entity, folder.id);
          } else if (entity is File) {
            directPaths.add(entity.path);
          }
        }
      } on FileSystemException {
        failedPaths.add(current.path);
      }
      final result = await _importFiles(
        directPaths,
        folderId: folder.id,
        sourceImport: true,
      );
      added.addAll(result.added);
      failedPaths.addAll(result.failedPaths);
      duplicateCount += result.duplicateCount;
      unsupportedCount += result.unsupportedCount;
    }

    try {
      if (await FileSystemEntity.type(rootPath, followLinks: false) ==
          FileSystemEntityType.directory) {
        await scan(Directory(rootPath), parentId);
      } else {
        failedPaths.add(rootPath);
      }
    } on FileSystemException {
      failedPaths.add(rootPath);
    }

    return LocalVideoImportResult(
      added: added,
      failedPaths: failedPaths,
      duplicateCount: duplicateCount,
      unsupportedCount: unsupportedCount,
    );
  }

  Future<LocalVideoImportResult> refreshFolder(String id) async {
    await initializeLibraryLayout();
    final folder = _folder(id);
    final failedPaths = <String>[];
    if (folder.isDisk && !await Directory(folder.directoryPath!).exists()) {
      failedPaths.add(folder.directoryPath!);
    }
    for (final video in videosIn(id)) {
      if (!await File(video.path).exists()) {
        failedPaths.add(video.path);
      }
    }
    return LocalVideoImportResult(added: const [], failedPaths: failedPaths);
  }

  Future<void> remove(String id) async {
    await initializeLibraryLayout();
    final referenceFolders = [...folders, ?_rootFolder];
    for (final folder in referenceFolders.where(
      (folder) => folder.videoIds.contains(id),
    )) {
      await _putFolder(
        folder.copyWith(
          videoIds: folder.videoIds.where((videoId) => videoId != id).toList(),
        ),
      );
    }
    await _box.delete(id);
  }

  Future<void> saveProgress(
    String id,
    Duration position,
    Duration duration,
  ) async {
    await initializeLibraryLayout();
    final video = findById(id);
    if (video == null) {
      return;
    }
    final updated = video.copyWith(
      positionMilliseconds: position.inMilliseconds,
      durationMilliseconds: duration.inMilliseconds,
    );
    await _box.put(id, jsonEncode(updated.toJson()));
  }

  Future<void> setDanmakuBinding(
    String id,
    LocalDanmakuBinding? binding,
  ) async {
    await initializeLibraryLayout();
    final video = findById(id);
    if (video == null) {
      return;
    }
    final updated = video.copyWith(
      danmakuBinding: binding,
      clearDanmakuBinding: binding == null,
    );
    await _box.put(id, jsonEncode(updated.toJson()));
  }

  Future<void> setSubtitleSettings(
    String id,
    LocalSubtitleSettings? settings,
  ) async {
    await initializeLibraryLayout();
    final video = findById(id);
    if (video == null) {
      return;
    }
    final updated = video.copyWith(
      subtitleSettings: settings,
      clearSubtitleSettings: settings == null,
    );
    await _box.put(id, jsonEncode(updated.toJson()));
  }

  Box<String> _requireFoldersBox() =>
      _foldersBox ?? (throw StateError('Folder storage is not configured'));

  Future<void> _putFolder(LocalVideoFolder folder) =>
      _requireFoldersBox().put(folder.id, jsonEncode(folder.toJson()));

  LocalVideoFolder _folder(String id) {
    _requireFoldersBox();
    return findFolderById(id) ??
        (throw ArgumentError.value(id, 'folderId', 'Folder does not exist'));
  }

  LocalVideoFolder _membershipFolder(String? folderId) =>
      folderId == null ? _rootFolder! : _folder(folderId);

  void _validateParent(String? parentId) {
    if (parentId != null) {
      _folder(parentId);
    }
  }

  static String _folderName(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError.value(name, 'name', 'Folder name cannot be empty');
    }
    return trimmed;
  }

  LocalVideoFolder? _diskFolderAt(String directory) {
    final identity = _pathIdentity(directory);
    for (final folder in folders) {
      if (folder.isDisk && _pathIdentity(folder.directoryPath!) == identity) {
        return folder;
      }
    }
    return null;
  }

  Future<LocalVideoFolder> _registerDiskFolder(
    String directory, {
    String? parentId,
  }) async {
    final existing = _diskFolderAt(directory);
    if (existing != null) {
      return existing;
    }
    final identity = _pathIdentity(directory);
    final directoryPath = path.normalize(path.absolute(directory));
    final folder = LocalVideoFolder(
      id: sha256.convert(utf8.encode('folder:$identity')).toString(),
      name: path.basename(directoryPath),
      type: LocalVideoFolderType.disk,
      parentId: parentId,
      directoryPath: directoryPath,
    );
    await _putFolder(folder);
    return folder;
  }

  static String _pathIdentity(String value) =>
      path.normalize(path.absolute(value)).replaceAll(r'\', '/').toLowerCase();

  static int _compareVideos(LocalVideo a, LocalVideo b) {
    final order = _compareNames(a.name, b.name);
    return order == 0 ? a.id.compareTo(b.id) : order;
  }

  static int _compareNames(String a, String b) {
    final pattern = RegExp(r'\d+|\D+');
    final aParts = pattern
        .allMatches(a.toLowerCase())
        .map((match) => match[0]!)
        .toList();
    final bParts = pattern
        .allMatches(b.toLowerCase())
        .map((match) => match[0]!)
        .toList();
    for (var i = 0; i < aParts.length && i < bParts.length; i++) {
      final aNumber = BigInt.tryParse(aParts[i]);
      final bNumber = BigInt.tryParse(bParts[i]);
      final order = aNumber != null && bNumber != null
          ? aNumber.compareTo(bNumber)
          : aParts[i].compareTo(bParts[i]);
      if (order != 0) {
        return order;
      }
    }
    final lengthOrder = aParts.length.compareTo(bParts.length);
    return lengthOrder == 0 ? a.compareTo(b) : lengthOrder;
  }
}
