import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:kazumi/modules/local_video/local_video.dart';
import 'package:kazumi/repositories/local_video_repository.dart';
import 'package:path/path.dart' as path;

void main() {
  late Directory temporary;
  late Directory media;
  late Box<String> videoBox;
  late Box<String> folderBox;
  late LocalVideoRepository repository;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('kazumi_video_folders_');
    media = await Directory(path.join(temporary.path, 'media')).create();
    Hive.init(path.join(temporary.path, 'hive'));
    videoBox = await Hive.openBox<String>('videos');
    folderBox = await Hive.openBox<String>('folders');
    repository = LocalVideoRepository(videoBox, foldersBox: folderBox);
  });

  tearDown(() async {
    await Hive.close();
    await temporary.delete(recursive: true);
  });

  Future<File> createVideo(String relativePath, {Directory? directory}) async {
    final file = File(path.join((directory ?? media).path, relativePath));
    await file.parent.create(recursive: true);
    return file.writeAsBytes([1, 2, 3]);
  }

  test('folder store reopens without rewriting existing video JSON', () async {
    final file = await createVideo('1.mp4');
    final video = (await repository.importFiles([file.path])).added.single;
    await repository.saveProgress(
      video.id,
      const Duration(seconds: 21),
      const Duration(minutes: 23),
    );
    await repository.setDanmakuBinding(
      video.id,
      const LocalDanmakuBinding(
        episodeId: 7,
        animeTitle: 'Series',
        episodeTitle: '1',
      ),
    );
    await repository.setSubtitleSettings(
      video.id,
      const LocalSubtitleSettings(
        source: LocalSubtitleSource.external,
        externalPath: 'local.ass',
      ),
    );
    final originalJson = videoBox.get(video.id);
    final classification = await repository.createVirtualFolder('分类');
    await repository.importDirectory(media.path, parentId: classification.id);
    await repository.addVideosToFolder(classification.id, [video.id]);
    final disk = repository.foldersIn(classification.id).single;

    await Hive.close();
    videoBox = await Hive.openBox<String>('videos');
    folderBox = await Hive.openBox<String>('folders');
    repository = LocalVideoRepository(videoBox, foldersBox: folderBox);

    expect(videoBox.get(video.id), originalJson);
    expect(repository.findFolderById(disk.id)!.directoryPath, media.path);
    expect(repository.findFolderById(classification.id)!.videoIds, [video.id]);
    expect(repository.findById(video.id)!.positionMilliseconds, 21000);
    expect(repository.findById(video.id)!.danmakuBinding!.episodeId, 7);
    expect(
      repository.findById(video.id)!.subtitleSettings!.externalPath,
      'local.ass',
    );
    expect(folderBox.length, 3);
    expect(jsonDecode(folderBox.get(disk.id)!)['type'], 'disk');
  });

  test(
    'recursive import preserves empty folders and direct layer membership',
    () async {
      await Directory(path.join(media.path, 'empty')).create();
      final direct = await createVideo('1.mp4');
      final nested = await createVideo(path.join('season', '2.mkv'));
      final loose = await createVideo('loose.mp4', directory: temporary);
      final looseVideo = (await repository.importFiles([
        loose.path,
      ])).added.single;
      final group = await repository.createVirtualFolder('收藏');
      await repository.addVideosToFolder(group.id, [looseVideo.id]);

      final result = await repository.importDirectory(media.path);
      final root = repository
          .foldersIn(null)
          .singleWhere((item) => item.isDisk);
      final children = repository.foldersIn(root.id);
      final season = children.singleWhere((item) => item.name == 'season');

      expect(result.added, hasLength(2));
      expect(root.parentId, isNull);
      expect(root.isVirtual, isFalse);
      expect(children.map((item) => item.name), ['empty', 'season']);
      expect(repository.videosIn(root.id).single.path, direct.path);
      expect(repository.videosIn(season.id).single.path, nested.path);
      expect(repository.videosIn(null).map((item) => item.id), [looseVideo.id]);
      expect(repository.videosIn(group.id).map((item) => item.id), [
        looseVideo.id,
      ]);
    },
  );

  test(
    'root keeps imported videos in an unregistered descendant directory',
    () async {
      await repository.importDirectory(media.path);
      final disk = repository.folders.single;
      final file = await createVideo(path.join('new-child', '1.mp4'));

      final result = await repository.importFiles([file.path]);

      expect(result.added, hasLength(1));
      expect(repository.foldersIn(disk.id), isEmpty);
      expect(repository.videosIn(disk.id), isEmpty);
      expect(repository.videosIn(null).map((video) => video.id), [
        result.added.single.id,
      ]);
    },
  );

  test('root keeps videos after removing disk child metadata', () async {
    final file = await createVideo(path.join('child', '1.mp4'));
    await repository.importDirectory(media.path);
    final disk = repository.foldersIn(null).single;
    final child = repository.foldersIn(disk.id).single;
    final video = repository.videosIn(child.id).single;

    await repository.removeFolder(child.id);

    expect(repository.findFolderById(disk.id), isNotNull);
    expect(repository.findFolderById(child.id), isNull);
    expect(repository.videosIn(disk.id), isEmpty);
    expect(repository.videosIn(null).map((item) => item.id), [video.id]);
    expect(await file.readAsBytes(), [1, 2, 3]);
  });

  test(
    'overlapping imports deduplicate paths and preserve organized parents',
    () async {
      final file = await createVideo(path.join('season', 'arc', '1.mp4'));
      final seasonPath = path.join(media.path, 'season');
      final arcPath = path.join(seasonPath, 'arc');
      final group = await repository.createVirtualFolder('导入');
      await repository.importDirectory(arcPath, parentId: group.id);
      final arcId = repository.foldersIn(group.id).single.id;

      await repository.importDirectory(media.path);
      final root = repository
          .foldersIn(null)
          .singleWhere((item) => item.isDisk);
      final season = repository.foldersIn(root.id).single;
      final arc = repository.findFolderById(arcId)!;
      expect(repository.foldersIn(season.id), isEmpty);
      final variant = Platform.isWindows
          ? seasonPath.toUpperCase().replaceAll(r'\', '/')
          : path.join(seasonPath, '.', 'unused', '..');
      final duplicate = await repository.importDirectory(variant);

      expect(arc.id, arcId);
      expect(repository.folders.where((item) => item.isDisk), hasLength(3));
      expect(repository.foldersIn(group.id).single.id, arcId);
      expect(repository.findFolderById(arcId)!.parentId, group.id);
      expect(repository.videosIn(arcId).single.path, file.path);
      expect(duplicate.added, isEmpty);
      expect(duplicate.duplicateCount, 1);
      expect(repository.findFolderById(root.id)!.directoryPath, media.path);
    },
  );

  test(
    'refresh retains stored members without scanning new files or folders',
    () async {
      final original = await createVideo('1.mp4');
      await Directory(path.join(media.path, 'old-empty')).create();
      await repository.importDirectory(media.path);
      final root = repository.foldersIn(null).single;
      final originalVideo = repository.videosIn(root.id).single;
      final newDirect = await createVideo('2.mp4');
      final deep = await createVideo(path.join('new-child', '3.mp4'));
      await original.delete();
      await Directory(path.join(media.path, 'old-empty')).delete();

      final refreshed = await repository.refreshFolder(root.id);

      expect(refreshed.added, isEmpty);
      expect(refreshed.failedPaths, [original.path]);
      expect(repository.findById(originalVideo.id), isNotNull);
      expect(repository.foldersIn(root.id).map((item) => item.name), [
        'old-empty',
      ]);
      expect(repository.videosIn(root.id).single.id, originalVideo.id);
      expect(
        repository.videos.any((item) => item.path == newDirect.path),
        isFalse,
      );
      expect(repository.videos.any((item) => item.path == deep.path), isFalse);

      await repository.importDirectory(media.path);
      final child = repository
          .foldersIn(root.id)
          .singleWhere((item) => item.name == 'new-child');

      expect(repository.videosIn(child.id).single.path, deep.path);
      expect(repository.videosIn(root.id), hasLength(2));
    },
  );

  test(
    'refresh retains unavailable directory metadata and reports the path',
    () async {
      await repository.importDirectory(media.path);
      final folder = repository.folders.single;
      await media.delete();

      final result = await repository.refreshFolder(folder.id);

      expect(result.added, isEmpty);
      expect(result.failedPaths, [media.path]);
      expect(repository.findFolderById(folder.id)!.directoryPath, media.path);
      expect(repository.foldersIn(null).single.id, folder.id);
    },
  );

  test(
    'virtual references support duplicate import and multiple classifications',
    () async {
      final file = await createVideo('1.mp4');
      final video = (await repository.importFiles([file.path])).added.single;
      final first = await repository.createVirtualFolder('第一类');
      final second = await repository.createVirtualFolder('第二类');
      final nested = await repository.createVirtualFolder(
        '子类',
        parentId: first.id,
      );

      final result = await repository.importFiles([
        file.path,
      ], folderId: nested.id);
      await repository.addVideosToFolder(second.id, [video.id, video.id]);
      await repository.renameFolder(nested.id, '改名');

      expect(result.duplicateCount, 1);
      expect(repository.findFolderById(nested.id)!.name, '改名');
      expect(repository.findFolderById(nested.id)!.parentId, first.id);
      expect(repository.findFolderById(second.id)!.videoIds, [video.id]);
      expect(repository.videosIn(nested.id).single.id, video.id);
      expect(repository.videosIn(second.id).single.id, video.id);
      expect(repository.videosIn(null).single.id, video.id);

      await repository.removeVideoFromFolder(nested.id, video.id);

      expect(repository.videosIn(nested.id), isEmpty);
      expect(repository.videosIn(second.id).single.id, video.id);
      expect(repository.findById(video.id), isNotNull);
      expect(await file.readAsBytes(), [1, 2, 3]);
    },
  );

  test(
    'disk folders allow logical children rename and outside file imports',
    () async {
      final direct = await createVideo('1.mp4');
      final outside = await createVideo('outside.mp4', directory: temporary);
      await repository.importDirectory(media.path);
      final disk = repository.folders.single;
      final video = repository.videos.single;

      final child = await repository.createVirtualFolder(
        'child',
        parentId: disk.id,
      );
      await repository.renameFolder(disk.id, 'renamed');
      await repository.addVideosToFolder(disk.id, [video.id]);
      final imported = await repository.importFiles([
        outside.path,
        direct.path,
      ], folderId: disk.id);

      expect(imported.failedPaths, isEmpty);
      expect(imported.duplicateCount, 1);
      expect(repository.findFolderById(disk.id)!.name, 'renamed');
      expect(repository.findFolderById(disk.id)!.directoryPath, media.path);
      expect(repository.foldersIn(disk.id).single.id, child.id);
      expect(repository.videosIn(disk.id), hasLength(2));
      expect(repository.videosIn(null), isEmpty);
      expect(repository.videos, hasLength(2));
      expect(repository.folders, hasLength(2));
    },
  );

  test(
    'removing folder subtrees only removes metadata and keeps source files',
    () async {
      final direct = await createVideo('1.mp4');
      final nested = await createVideo(path.join('season', '2.mp4'));
      final classification = await repository.createVirtualFolder('分类');
      final child = await repository.createVirtualFolder(
        '子类',
        parentId: classification.id,
      );
      await repository.importDirectory(media.path);
      final disk = repository
          .foldersIn(null)
          .singleWhere((item) => item.isDisk);
      await repository.addVideosToFolder(
        child.id,
        repository.videos.map((item) => item.id),
      );

      await repository.removeFolder(classification.id);

      expect(repository.findFolderById(child.id), isNull);
      expect(repository.videos, hasLength(2));
      expect(repository.videosIn(null), isEmpty);

      await repository.removeFolder(disk.id);

      expect(repository.folders, isEmpty);
      expect(repository.videosIn(null), hasLength(2));
      expect(await direct.readAsBytes(), [1, 2, 3]);
      expect(await nested.readAsBytes(), [1, 2, 3]);
    },
  );

  test(
    'removing a video cleans every virtual reference without deleting file',
    () async {
      final file = await createVideo('1.mp4');
      final video = (await repository.importFiles([file.path])).added.single;
      for (final name in ['one', 'two']) {
        final folder = await repository.createVirtualFolder(name);
        await repository.addVideosToFolder(folder.id, [video.id]);
      }

      await repository.remove(video.id);

      expect(repository.videos, isEmpty);
      expect(repository.folders.every((item) => item.videoIds.isEmpty), isTrue);
      expect(await file.readAsBytes(), [1, 2, 3]);
    },
  );

  test(
    'scoped playlists include only current layer in natural order',
    () async {
      for (final name in ['10.mp4', '2.mp4', '1.mp4']) {
        await createVideo(name);
      }
      await createVideo(path.join('child', '3.mp4'));
      await repository.importDirectory(media.path);
      final disk = repository.foldersIn(null).single;
      final direct = repository.videosIn(disk.id);
      final child = repository.foldersIn(disk.id).single;
      final group = await repository.createVirtualFolder('mixed');
      final nestedVideo = repository.videosIn(child.id).single;
      await repository.addVideosToFolder(group.id, [
        direct.last.id,
        nestedVideo.id,
        direct.first.id,
      ]);

      expect(
        repository
            .playlistInFolder(direct.first.id, folderId: disk.id)
            .map((item) => item.name),
        ['1.mp4', '2.mp4', '10.mp4'],
      );
      expect(
        repository
            .playlistInFolder(direct.first.id, folderId: group.id)
            .map((item) => item.name),
        ['1.mp4', '3.mp4', '10.mp4'],
      );
      expect(
        repository.playlistInFolder(nestedVideo.id, folderId: disk.id),
        isEmpty,
      );
      expect(repository.playlistInFolder(direct.first.id), isEmpty);
      expect(
        repository.playlistInFolder('missing', folderId: group.id),
        isEmpty,
      );
      expect(repository.playlistFor(direct.first.id), hasLength(3));
    },
  );

  test(
    'classification subtree deletion preserves references shared elsewhere',
    () async {
      final file = await createVideo('shared.mp4');
      final video = (await repository.importFiles([file.path])).added.single;
      final first = await repository.createVirtualFolder('first');
      final nested = await repository.createVirtualFolder(
        'nested',
        parentId: first.id,
      );
      final second = await repository.createVirtualFolder('second');
      await repository.addVideosToFolder(nested.id, [video.id]);
      await repository.addVideosToFolder(second.id, [video.id]);

      await repository.removeFolder(first.id);

      expect(repository.findFolderById(nested.id), isNull);
      expect(repository.videosIn(second.id).single.id, video.id);
      expect(repository.findById(video.id), isNotNull);
      expect(await file.readAsBytes(), [1, 2, 3]);
    },
  );

  test('new file imports attach to a nested virtual folder', () async {
    final file = await createVideo('new.mp4');
    final parent = await repository.createVirtualFolder('parent');
    final nested = await repository.createVirtualFolder(
      'nested',
      parentId: parent.id,
    );

    final result = await repository.importFiles([
      file.path,
    ], folderId: nested.id);

    expect(result.added, hasLength(1));
    expect(repository.videosIn(nested.id).single.id, result.added.single.id);
    expect(repository.videosIn(parent.id), isEmpty);
    expect(repository.videosIn(null), isEmpty);
  });

  test('folder mutations require persistent storage', () async {
    final legacy = LocalVideoRepository(videoBox);

    expect(legacy.folders, isEmpty);
    expect(legacy.foldersIn(null), isEmpty);
    await expectLater(
      legacy.createVirtualFolder('not persisted'),
      throwsStateError,
    );
    await expectLater(legacy.importDirectory(media.path), throwsStateError);
  });
}
