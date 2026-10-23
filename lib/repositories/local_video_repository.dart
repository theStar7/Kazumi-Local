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
      .toList();

  LocalVideo? findById(String id) {
    final value = _box.get(id);
    return value == null
        ? null
        : LocalVideo.fromJson(jsonDecode(value) as Map<String, dynamic>);
  }

  LocalVideoFolder? findFolderById(String id) {
    final value = _foldersBox?.get(id);
    return value == null
        ? null
        : LocalVideoFolder.fromJson(jsonDecode(value) as Map<String, dynamic>);
  }

  List<LocalVideoFolder> foldersIn(String? parentId) =>
      folders.where((folder) => folder.parentId == parentId).toList()
        ..sort((a, b) => _compareNames(a.name, b.name));

  List<LocalVideo> videosIn(String? folderId) {
    final allVideos = videos;
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
    _validateVirtualParent(parentId);
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
    final folder = _virtualFolder(id);
    await _putFolder(folder.copyWith(name: _folderName(name)));
  }

  Future<void> addVideosToFolder(
    String folderId,
    Iterable<String> videoIds,
  ) async {
    final folder = _virtualFolder(folderId);
    final references = folder.videoIds.toSet();
    for (final id in videoIds) {
      if (findById(id) == null) {
        throw ArgumentError.value(id, 'videoIds', 'Video does not exist');
      }
      references.add(id);
    }
    await _putFolder(folder.copyWith(videoIds: references.toList()));
  }

  Future<void> removeVideoFromFolder(String folderId, String videoId) async {
    final folder = _virtualFolder(folderId);
    await _putFolder(
      folder.copyWith(
        videoIds: folder.videoIds.where((id) => id != videoId).toList(),
      ),
    );
  }

  Future<void> removeFolder(String id) async {
    final box = _requireFoldersBox();
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
    await box.deleteAll(removedIds);
  }

  Future<LocalVideoImportResult> importFiles(
    Iterable<String> paths, {
    String? folderId,
  }) async {
    final folder = folderId == null ? null : _folder(folderId);
    final references = <String>[];
    final added = <LocalVideo>[];
    final failedPaths = <String>[];
    var duplicateCount = 0;
    var unsupportedCount = 0;
    for (final input in paths) {
      final absolutePath = path.normalize(path.absolute(input));
      if (folder != null &&
          folder.isDisk &&
          _pathIdentity(path.dirname(absolutePath)) !=
              _pathIdentity(folder.directoryPath!)) {
        failedPaths.add(absolutePath);
        continue;
      }
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
      references.add(id);
      if (_box.containsKey(id)) {
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
    if (folder != null && folder.isVirtual) {
      await addVideosToFolder(folder.id, references);
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
    _validateVirtualParent(parentId);
    final rootPath = path.normalize(path.absolute(directory));
    final paths = <String>[];
    final failedPaths = <String>[];

    Future<void> scan(Directory current, String? parentId) async {
      final folder = await _registerDiskFolder(
        current.path,
        parentId: parentId,
      );
      try {
        await for (final entity in current.list(followLinks: false)) {
          if (entity is Directory) {
            await scan(entity, folder.id);
          } else if (entity is File) {
            paths.add(entity.path);
          }
        }
      } on FileSystemException {
        failedPaths.add(current.path);
      }
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

    await _reconcileDiskParents();
    final result = await importFiles(paths);
    return LocalVideoImportResult(
      added: result.added,
      failedPaths: [...failedPaths, ...result.failedPaths],
      duplicateCount: result.duplicateCount,
      unsupportedCount: result.unsupportedCount,
    );
  }

  Future<LocalVideoImportResult> refreshFolder(String id) async {
    final folder = _folder(id);
    if (folder.isVirtual) {
      return const LocalVideoImportResult(added: [], failedPaths: []);
    }
    final directory = folder.directoryPath!;
    final paths = <String>[];
    final failedPaths = <String>[];
    try {
      if (await FileSystemEntity.type(directory, followLinks: false) !=
          FileSystemEntityType.directory) {
        failedPaths.add(directory);
      } else {
        await for (final entity in Directory(
          directory,
        ).list(followLinks: false)) {
          if (entity is Directory) {
            await _registerDiskFolder(entity.path, parentId: folder.id);
          } else if (entity is File) {
            paths.add(entity.path);
          }
        }
      }
    } on FileSystemException {
      failedPaths.add(directory);
    }
    await _reconcileDiskParents();
    final result = await importFiles(paths, folderId: folder.id);
    return LocalVideoImportResult(
      added: result.added,
      failedPaths: [...failedPaths, ...result.failedPaths],
      duplicateCount: result.duplicateCount,
      unsupportedCount: result.unsupportedCount,
    );
  }

  Future<void> remove(String id) async {
    for (final folder in folders.where(
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

  LocalVideoFolder _virtualFolder(String id) {
    final folder = _folder(id);
    if (!folder.isVirtual) {
      throw ArgumentError.value(
        id,
        'folderId',
        'Disk folders follow the filesystem',
      );
    }
    return folder;
  }

  void _validateVirtualParent(String? parentId) {
    if (parentId != null) {
      _virtualFolder(parentId);
    }
  }

  static String _folderName(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError.value(name, 'name', 'Folder name cannot be empty');
    }
    return trimmed;
  }

  Future<LocalVideoFolder> _registerDiskFolder(
    String directory, {
    String? parentId,
  }) async {
    final identity = _pathIdentity(directory);
    for (final folder in folders) {
      if (folder.isDisk && _pathIdentity(folder.directoryPath!) == identity) {
        return folder;
      }
    }
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

  Future<void> _reconcileDiskParents() async {
    final diskFolders = folders.where((folder) => folder.isDisk).toList();
    for (final folder in diskFolders) {
      LocalVideoFolder? nearest;
      for (final candidate in diskFolders) {
        if (_isWithin(candidate.directoryPath!, folder.directoryPath!) &&
            (nearest == null ||
                candidate.directoryPath!.length >
                    nearest.directoryPath!.length)) {
          nearest = candidate;
        }
      }
      if (nearest != null && folder.parentId != nearest.id) {
        await _putFolder(folder.copyWith(parentId: nearest.id));
      }
    }
  }

  static String _pathIdentity(String value) =>
      path.normalize(path.absolute(value)).replaceAll(r'\', '/').toLowerCase();

  static bool _isWithin(String directory, String target) =>
      path.posix.isWithin(_pathIdentity(directory), _pathIdentity(target));

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
