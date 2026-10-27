import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:kazumi/modules/local_video/local_video.dart';
import 'package:kazumi/modules/local_video/local_video_folder.dart';
import 'package:kazumi/repositories/local_video_repository.dart';
import 'package:path/path.dart' as path;

void main() {
  late Directory temporary;
  late Directory media;
  late Box<String> videoBox;
  late Box<String> folderBox;
  late LocalVideoRepository repository;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('kazumi_video_moves_');
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

  Future<File> createVideo(String name) async {
    final file = File(path.join(media.path, name));
    await file.parent.create(recursive: true);
    return file.writeAsBytes([1, 2, 3]);
  }

  Future<void> seedFolder(LocalVideoFolder folder) =>
      folderBox.put(folder.id, jsonEncode(folder.toJson()));

  test(
    'first mutation migrates legacy direct membership and visible root',
    () async {
      final diskVideo = LocalVideo(
        id: 'disk-video',
        path: path.join(media.path, '1.mp4'),
        name: '1.mp4',
      );
      final looseVideo = LocalVideo(
        id: 'loose-video',
        path: path.join(temporary.path, '2.mp4'),
        name: '2.mp4',
      );
      await videoBox.put(diskVideo.id, jsonEncode(diskVideo.toJson()));
      await videoBox.put(looseVideo.id, jsonEncode(looseVideo.toJson()));
      final originalVideoJson = videoBox.toMap();
      await seedFolder(
        LocalVideoFolder(
          id: 'disk',
          name: 'renamed',
          type: LocalVideoFolderType.disk,
          parentId: 'category',
          directoryPath: media.path,
        ),
      );
      await seedFolder(
        LocalVideoFolder(
          id: 'category',
          name: 'category',
          type: LocalVideoFolderType.virtual,
          videoIds: [looseVideo.id],
        ),
      );

      await repository.createVirtualFolder('new');

      expect(repository.findFolderById('disk')!.videoIds, [diskVideo.id]);
      expect(jsonDecode(folderBox.get('disk')!)['sourceVideoIds'], [
        diskVideo.id,
      ]);
      expect(repository.findFolderById('disk')!.parentId, 'category');
      expect(repository.findFolderById('disk')!.name, 'renamed');
      expect(repository.findFolderById('category')!.videoIds, [looseVideo.id]);
      expect(repository.videosIn(null).map((video) => video.id), [
        looseVideo.id,
      ]);
      expect(videoBox.toMap(), originalVideoJson);
      expect(folderBox.length, repository.folders.length + 1);
      final hiddenId =
          folderBox.keys.singleWhere(
                (key) => !repository.folders.any((folder) => folder.id == key),
              )
              as String;
      expect(repository.findFolderById(hiddenId), isNull);
    },
  );

  test(
    'disk folders accept logical children rename and outside references',
    () async {
      await createVideo('1.mp4');
      await repository.importDirectory(media.path);
      final disk = repository.folders.single;
      final outside = File(path.join(temporary.path, 'outside.mp4'));
      await outside.writeAsBytes([4]);

      final child = await repository.createVirtualFolder(
        'child',
        parentId: disk.id,
      );
      await repository.renameFolder(disk.id, 'organized');
      final imported = await repository.importFiles([
        outside.path,
      ], folderId: disk.id);

      expect(repository.findFolderById(disk.id)!.name, 'organized');
      expect(repository.findFolderById(disk.id)!.directoryPath, media.path);
      expect(child.parentId, disk.id);
      expect(imported.failedPaths, isEmpty);
      expect(repository.videosIn(disk.id), hasLength(2));
      expect(repository.videosIn(null), isEmpty);
      expect(await outside.readAsBytes(), [4]);
    },
  );

  test('refresh checks status without discovering files or folders', () async {
    final existing = await createVideo('1.mp4');
    await repository.importDirectory(media.path);
    final disk = repository.folders.single;
    final original = repository.videos.single;
    await existing.delete();
    await createVideo('2.mp4');
    await createVideo(path.join('child', '3.mp4'));

    final result = await repository.refreshFolder(disk.id);

    expect(result.added, isEmpty);
    expect(result.failedPaths, [existing.path]);
    expect(repository.videos.single.id, original.id);
    expect(repository.foldersIn(disk.id), isEmpty);
    expect(repository.videosIn(disk.id).single.id, original.id);
  });

  test('folder-targeted import creates only the requested reference', () async {
    final file = await createVideo('1.mp4');
    final folder = await repository.createVirtualFolder('target');

    final result = await repository.importFiles([
      file.path,
    ], folderId: folder.id);

    expect(repository.videosIn(folder.id).single.id, result.added.single.id);
    expect(repository.videosIn(null), isEmpty);
  });

  test(
    'initialization persists once across concurrent calls and reopen',
    () async {
      final video = LocalVideo(
        id: 'legacy',
        path: path.join(media.path, '1.mp4'),
        name: '1.mp4',
      );
      await videoBox.put(video.id, jsonEncode(video.toJson()));
      await seedFolder(
        LocalVideoFolder(
          id: 'source',
          name: 'source',
          type: LocalVideoFolderType.disk,
          directoryPath: media.path,
        ),
      );
      final observed = _ObservedFolderBox(folderBox);
      repository = LocalVideoRepository(videoBox, foldersBox: observed);

      await Future.wait(
        List.generate(4, (_) => repository.initializeLibraryLayout()),
      );

      expect(observed.putKeys, hasLength(2));
      final saved = folderBox.toMap();
      final rootKey =
          folderBox.keys.singleWhere((key) => key != 'source') as String;
      expect(repository.findFolderById(rootKey), isNull);
      expect(repository.folders.map((folder) => folder.id), ['source']);
      await expectLater(
        repository.createVirtualFolder('hidden child', parentId: rootKey),
        throwsArgumentError,
      );
      await expectLater(
        repository.addVideosToFolder(rootKey, [video.id]),
        throwsArgumentError,
      );
      await expectLater(
        repository.moveVideo(
          video.id,
          fromFolderId: 'source',
          toFolderId: rootKey,
        ),
        throwsArgumentError,
      );
      expect(repository.canMoveFolder('source', rootKey), isFalse);

      await Hive.close();
      videoBox = await Hive.openBox<String>('videos');
      folderBox = await Hive.openBox<String>('folders');
      repository = LocalVideoRepository(videoBox, foldersBox: folderBox);
      await repository.initializeLibraryLayout();
      expect(folderBox.toMap(), saved);
      expect(repository.videosIn('source').single.id, video.id);
    },
  );

  test(
    'failed migration writes no marker and retries partial folder writes',
    () async {
      for (final id in ['first', 'second']) {
        final source = path.join(media.path, id);
        final video = LocalVideo(
          id: id,
          path: path.join(source, '1.mp4'),
          name: '1.mp4',
        );
        await videoBox.put(id, jsonEncode(video.toJson()));
        await seedFolder(
          LocalVideoFolder(
            id: id,
            name: id,
            type: LocalVideoFolderType.disk,
            directoryPath: source,
          ),
        );
      }
      final failing = _ObservedFolderBox(folderBox)..failNextKey = 'second';
      repository = LocalVideoRepository(videoBox, foldersBox: failing);

      await expectLater(repository.initializeLibraryLayout(), throwsStateError);

      expect(folderBox.length, 2);
      expect(repository.findFolderById('first')!.videoIds, ['first']);
      await repository.initializeLibraryLayout();
      expect(folderBox.length, 3);
      expect(repository.findFolderById('second')!.videoIds, ['second']);
      expect(repository.videosIn(null), isEmpty);
    },
  );

  test(
    'video moves change only the source reference and deduplicate target',
    () async {
      final file = await createVideo('1.mp4');
      final video = (await repository.importFiles([file.path])).added.single;
      final first = await repository.createVirtualFolder('first');
      final other = await repository.createVirtualFolder('other');
      await repository.addVideosToFolder(first.id, [video.id]);
      await repository.addVideosToFolder(other.id, [video.id]);
      final originalJson = videoBox.get(video.id);
      await file.delete();

      await repository.moveVideo(video.id, toFolderId: first.id);

      expect(repository.videosIn(null), isEmpty);
      expect(repository.findFolderById(first.id)!.videoIds, [video.id]);
      expect(repository.videosIn(other.id).single.id, video.id);
      await repository.moveVideo(video.id, fromFolderId: first.id);
      expect(repository.videosIn(first.id), isEmpty);
      expect(repository.videosIn(null).single.id, video.id);
      expect(repository.videosIn(other.id).single.id, video.id);
      expect(videoBox.get(video.id), originalJson);
      await repository.moveVideo(video.id);
      await expectLater(repository.moveVideo('missing'), throwsArgumentError);
      await expectLater(
        repository.moveVideo(video.id, fromFolderId: first.id),
        throwsArgumentError,
      );
      await expectLater(
        repository.moveVideo(video.id, toFolderId: 'missing'),
        throwsArgumentError,
      );
    },
  );

  test(
    'failed move target write preserves source and all existing references',
    () async {
      final file = await createVideo('1.mp4');
      final video = (await repository.importFiles([file.path])).added.single;
      final target = await repository.createVirtualFolder('target');
      final originalFolders = folderBox.toMap();
      final failing = _ObservedFolderBox(folderBox)..failNextKey = target.id;
      repository = LocalVideoRepository(videoBox, foldersBox: failing);

      await expectLater(
        repository.moveVideo(video.id, toFolderId: target.id),
        throwsStateError,
      );

      expect(folderBox.toMap(), originalFolders);
      expect(repository.videosIn(null).single.id, video.id);
      expect(repository.videosIn(target.id), isEmpty);
      await repository.moveVideo(video.id, toFolderId: target.id);
      expect(repository.videosIn(null), isEmpty);
      expect(repository.videosIn(target.id).single.id, video.id);
    },
  );

  test(
    'folder move preserves subtree and prevents self descendant and invalid targets',
    () async {
      await createVideo(path.join('source-child', '1.mp4'));
      await repository.importDirectory(media.path);
      final source = repository.foldersIn(null).single;
      final nestedSource = repository.foldersIn(source.id).single;
      final child = await repository.createVirtualFolder(
        'child',
        parentId: source.id,
      );
      final target = await repository.createVirtualFolder('target');
      final nestedJson = folderBox.get(nestedSource.id);
      final videoJson = videoBox.toMap();

      expect(repository.canMoveFolder(source.id, source.id), isFalse);
      expect(repository.canMoveFolder(source.id, nestedSource.id), isFalse);
      expect(repository.canMoveFolder(source.id, child.id), isFalse);
      expect(repository.canMoveFolder(source.id, null), isFalse);
      expect(repository.canMoveFolder('missing', null), isFalse);
      expect(repository.canMoveFolder(source.id, 'missing'), isFalse);
      await expectLater(
        repository.moveFolder(source.id, child.id),
        throwsArgumentError,
      );
      await expectLater(
        repository.moveFolder(source.id, 'missing'),
        throwsArgumentError,
      );
      expect(repository.canMoveFolder(source.id, target.id), isTrue);

      await repository.moveFolder(source.id, target.id);
      expect(repository.findFolderById(source.id)!.parentId, target.id);
      expect(
        repository.findFolderById(source.id)!.copyWith(parentId: null).parentId,
        isNull,
      );
      expect(repository.findFolderById(child.id)!.parentId, source.id);
      expect(folderBox.get(nestedSource.id), nestedJson);
      await repository.moveFolder(source.id, null);
      expect(repository.findFolderById(source.id)!.parentId, isNull);
      expect(source.copyWith(parentId: null).parentId, isNull);
      await repository.moveFolder(source.id, null);
      expect(videoBox.toMap(), videoJson);
    },
  );

  test(
    'removing the final reference returns retained videos to root',
    () async {
      final file = await createVideo('1.mp4');
      final first = await repository.createVirtualFolder('first');
      final second = await repository.createVirtualFolder('second');
      final video = (await repository.importFiles([
        file.path,
      ], folderId: first.id)).added.single;
      await repository.addVideosToFolder(second.id, [video.id]);

      await repository.removeVideoFromFolder(first.id, video.id);
      expect(repository.videosIn(null), isEmpty);
      await repository.removeVideoFromFolder(second.id, video.id);

      expect(repository.videosIn(null).single.id, video.id);
      expect(repository.findById(video.id), isNotNull);
      expect(await file.readAsBytes(), [1, 2, 3]);
      await repository.remove(video.id);
      expect(repository.videosIn(null), isEmpty);
    },
  );

  test(
    'reimport preserves moves renamed source nodes and supplements new content',
    () async {
      final existing = await createVideo('1.mp4');
      await repository.importDirectory(media.path);
      final source = repository.folders.single;
      final video = repository.videos.single;
      final target = await repository.createVirtualFolder('target');
      await repository.renameFolder(source.id, 'organized');
      await repository.moveFolder(source.id, target.id);
      await repository.moveVideo(
        video.id,
        fromFolderId: source.id,
        toFolderId: target.id,
      );
      final newer = await createVideo('2.mp4');
      final childFile = await createVideo(path.join('new-child', '3.mp4'));

      final result = await repository.importDirectory(media.path);

      expect(result.added, hasLength(2));
      expect(result.duplicateCount, 1);
      expect(repository.findFolderById(source.id)!.name, 'organized');
      expect(repository.findFolderById(source.id)!.parentId, target.id);
      expect(
        repository.findFolderById(source.id)!.copyWith(parentId: null).parentId,
        isNull,
      );
      expect(repository.videosIn(source.id).single.path, newer.path);
      expect(repository.videosIn(target.id).single.path, existing.path);
      final newChild = repository.foldersIn(source.id).single;
      expect(repository.videosIn(newChild.id).single.path, childFile.path);
      expect(repository.videosIn(null), isEmpty);
      await repository.importFiles([existing.path], folderId: source.id);
      expect(repository.videosIn(source.id), hasLength(2));
    },
  );

  test(
    'first source snapshot references known videos without changing existing root reference',
    () async {
      final file = await createVideo('known.mp4');
      final video = (await repository.importFiles([file.path])).added.single;

      final result = await repository.importDirectory(media.path);

      final source = repository.folders.single;
      expect(result.added, isEmpty);
      expect(result.duplicateCount, 1);
      expect(repository.videosIn(source.id).single.id, video.id);
      expect(repository.videosIn(null).single.id, video.id);
    },
  );

  test(
    'failed directory reference write never persists an unlocated video',
    () async {
      await createVideo('new.mp4');
      await repository.importDirectory(media.path);
      final source = repository.folders.single;
      final original = repository.videos.single;
      await createVideo('later.mp4');
      final failing = _ObservedFolderBox(folderBox)..failNextKey = source.id;
      repository = LocalVideoRepository(videoBox, foldersBox: failing);

      await expectLater(
        repository.importDirectory(media.path),
        throwsStateError,
      );

      expect(repository.videos.map((video) => video.id), [original.id]);
      expect(repository.videosIn(source.id).single.id, original.id);
    },
  );

  test(
    'logical playlists retain natural order after source directory disappears',
    () async {
      for (final name in ['10.mp4', '2.mp4', '1.mp4']) {
        await createVideo(name);
      }
      await repository.importDirectory(media.path);
      final source = repository.folders.single;
      final target = await repository.createVirtualFolder('target');
      final all = repository.videosIn(source.id);
      for (final video in all) {
        await repository.moveVideo(
          video.id,
          fromFolderId: source.id,
          toFolderId: target.id,
        );
      }
      await media.delete(recursive: true);
      final refreshed = await repository.refreshFolder(source.id);

      expect(refreshed.added, isEmpty);
      expect(refreshed.failedPaths, [media.path]);
      expect(
        repository.playlistInFolder(all.first.id, folderId: source.id),
        isEmpty,
      );
      expect(
        repository
            .playlistInFolder(all.first.id, folderId: target.id)
            .map((video) => video.name),
        ['1.mp4', '2.mp4', '10.mp4'],
      );
    },
  );
  test(
    'root moves persist after reopen without re-deriving source paths',
    () async {
      final file = await createVideo('1.mp4');
      await repository.importDirectory(media.path);
      final source = repository.folders.single;
      final video = repository.videos.single;
      final target = await repository.createVirtualFolder('target');
      await repository.moveVideo(
        video.id,
        fromFolderId: source.id,
        toFolderId: target.id,
      );
      await repository.moveVideo(video.id, fromFolderId: target.id);

      await Hive.close();
      videoBox = await Hive.openBox<String>('videos');
      folderBox = await Hive.openBox<String>('folders');
      repository = LocalVideoRepository(videoBox, foldersBox: folderBox);
      await repository.initializeLibraryLayout();

      expect(repository.videosIn(source.id), isEmpty);
      expect(repository.videosIn(target.id), isEmpty);
      expect(repository.videosIn(null).single.id, video.id);
      await repository.importDirectory(media.path);
      expect(repository.videosIn(source.id), isEmpty);
      expect(repository.videosIn(null).single.id, video.id);
      expect(await file.readAsBytes(), [1, 2, 3]);
    },
  );

  test(
    'failure removing the move source retains both safe references',
    () async {
      final file = await createVideo('1.mp4');
      final source = await repository.createVirtualFolder('source');
      final target = await repository.createVirtualFolder('target');
      final video = (await repository.importFiles([
        file.path,
      ], folderId: source.id)).added.single;
      final failing = _ObservedFolderBox(folderBox)..failNextKey = source.id;
      repository = LocalVideoRepository(videoBox, foldersBox: failing);

      await expectLater(
        repository.moveVideo(
          video.id,
          fromFolderId: source.id,
          toFolderId: target.id,
        ),
        throwsStateError,
      );

      expect(repository.videosIn(source.id).single.id, video.id);
      expect(repository.videosIn(target.id).single.id, video.id);
      expect(repository.videosIn(null), isEmpty);
    },
  );

  test(
    'one-box constructor retains file import player updates and root behavior',
    () async {
      final file = await createVideo('1.mp4');
      final legacy = LocalVideoRepository(videoBox);

      await legacy.initializeLibraryLayout();
      final video = (await legacy.importFiles([file.path])).added.single;
      await legacy.saveProgress(
        video.id,
        const Duration(seconds: 12),
        const Duration(minutes: 20),
      );

      expect(legacy.folders, isEmpty);
      expect(folderBox.isEmpty, isTrue);
      expect(legacy.videosIn(null).single.id, video.id);
      expect(legacy.findById(video.id)!.positionMilliseconds, 12000);
      expect(legacy.playlistFor(video.id).single.id, video.id);
      await legacy.remove(video.id);
      expect(legacy.videosIn(null), isEmpty);
      expect(await file.readAsBytes(), [1, 2, 3]);
    },
  );
  test(
    'interrupted first source snapshot retries known reference after reopen',
    () async {
      final file = await createVideo('known.mp4');
      final video = (await repository.importFiles([file.path])).added.single;
      final failing = _ObservedFolderBox(folderBox)
        ..failPutWhen = (key, value) {
          final json = jsonDecode(value) as Map<String, dynamic>;
          return json['type'] == 'disk' &&
              (json['videoIds'] as List<dynamic>).contains(video.id);
        };
      repository = LocalVideoRepository(videoBox, foldersBox: failing);

      await expectLater(
        repository.importDirectory(media.path),
        throwsStateError,
      );

      final source = repository.folders.single;
      expect(repository.videosIn(source.id), isEmpty);
      expect(repository.videosIn(null).single.id, video.id);
      await Hive.close();
      videoBox = await Hive.openBox<String>('videos');
      folderBox = await Hive.openBox<String>('folders');
      repository = LocalVideoRepository(videoBox, foldersBox: folderBox);

      final retried = await repository.importDirectory(media.path);

      expect(retried.added, isEmpty);
      expect(retried.duplicateCount, 1);
      expect(repository.videosIn(source.id).map((video) => video.id), [
        video.id,
      ]);
      expect(repository.videosIn(null).single.id, video.id);
      expect(jsonDecode(folderBox.get(source.id)!)['sourceVideoIds'], [
        video.id,
      ]);
    },
  );

  test(
    'partial source retry supplements failed reference without undoing a move',
    () async {
      final firstFile = await createVideo('1.mp4');
      final secondFile = await createVideo('2.mp4');
      final known = (await repository.importFiles([
        firstFile.path,
        secondFile.path,
      ])).added;
      final failing = _ObservedFolderBox(folderBox)
        ..failPutWhen = (key, value) {
          final json = jsonDecode(value) as Map<String, dynamic>;
          return json['type'] == 'disk' &&
              (json['videoIds'] as List<dynamic>).length == 2;
        };
      repository = LocalVideoRepository(videoBox, foldersBox: failing);

      await expectLater(
        repository.importDirectory(media.path),
        throwsStateError,
      );

      final source = repository.folders.single;
      final succeeded = repository.videosIn(source.id).single;
      final failed = known.singleWhere((video) => video.id != succeeded.id);
      final target = await repository.createVirtualFolder('organized');
      await repository.moveVideo(
        succeeded.id,
        fromFolderId: source.id,
        toFolderId: target.id,
      );
      await Hive.close();
      videoBox = await Hive.openBox<String>('videos');
      folderBox = await Hive.openBox<String>('folders');
      repository = LocalVideoRepository(videoBox, foldersBox: folderBox);

      await repository.importDirectory(media.path);

      expect(repository.videosIn(source.id).map((video) => video.id), [
        failed.id,
      ]);
      expect(repository.videosIn(target.id).single.id, succeeded.id);
      expect(repository.videosIn(null), hasLength(2));
      expect(
        jsonDecode(folderBox.get(source.id)!)['sourceVideoIds'],
        unorderedEquals(known.map((video) => video.id)),
      );
      await repository.removeVideoFromFolder(source.id, failed.id);
      await repository.importDirectory(media.path);
      expect(repository.videosIn(source.id), isEmpty);
    },
  );

  test(
    'directory reimport locates a recreated record even when source saw it before',
    () async {
      final file = await createVideo('1.mp4');
      await repository.importDirectory(media.path);
      final source = repository.folders.single;
      final video = repository.videos.single;
      await repository.remove(video.id);

      final result = await repository.importDirectory(media.path);

      expect(result.added.single.id, video.id);
      expect(repository.videosIn(source.id).single.id, video.id);
      expect(repository.videosIn(null), isEmpty);
      expect(await file.readAsBytes(), [1, 2, 3]);
    },
  );
  for (final operation in [
    'file import',
    'add existing reference',
    'move target',
  ]) {
    test(
      'source reimport preserves a move after reference creation by $operation',
      () async {
        await repository.importDirectory(media.path);
        final source = repository.folders.single;
        final target = await repository.createVirtualFolder('target');
        final file = await createVideo('new.mp4');
        late LocalVideo video;
        if (operation == 'file import') {
          video = (await repository.importFiles([
            file.path,
          ], folderId: source.id)).added.single;
        } else {
          video = (await repository.importFiles([file.path])).added.single;
          if (operation == 'add existing reference') {
            await repository.addVideosToFolder(source.id, [video.id]);
          } else {
            await repository.moveVideo(video.id, toFolderId: source.id);
          }
        }
        await repository.moveVideo(
          video.id,
          fromFolderId: source.id,
          toFolderId: target.id,
        );

        await repository.importDirectory(media.path);

        expect(repository.videosIn(source.id), isEmpty);
        expect(repository.videosIn(target.id).single.id, video.id);
        expect(jsonDecode(folderBox.get(source.id)!)['sourceVideoIds'], [
          video.id,
        ]);
        expect(await file.readAsBytes(), [1, 2, 3]);
      },
    );
  }

  test(
    'adding an existing disk member persists missing source history',
    () async {
      await repository.importDirectory(media.path);
      final source = repository.folders.single;
      final file = await createVideo('known.mp4');
      final video = (await repository.importFiles([file.path])).added.single;
      await seedFolder(source.copyWith(videoIds: [video.id]));

      await repository.addVideosToFolder(source.id, [video.id]);

      expect(repository.findFolderById(source.id)!.videoIds, [video.id]);
      expect(jsonDecode(folderBox.get(source.id)!)['sourceVideoIds'], [
        video.id,
      ]);
      await repository.moveVideo(video.id, fromFolderId: source.id);
      await repository.importDirectory(media.path);
      expect(repository.videosIn(source.id), isEmpty);
    },
  );
}

class _ObservedFolderBox implements Box<String> {
  _ObservedFolderBox(this.delegate);

  final Box<String> delegate;
  final List<dynamic> putKeys = [];
  dynamic failNextKey;
  bool Function(dynamic key, String value)? failPutWhen;

  @override
  Iterable<String> get values => delegate.values;

  @override
  String? get(dynamic key, {String? defaultValue}) =>
      delegate.get(key, defaultValue: defaultValue);

  @override
  bool containsKey(dynamic key) => delegate.containsKey(key);

  @override
  Future<void> put(dynamic key, String value) async {
    putKeys.add(key);
    if (key == failNextKey || (failPutWhen?.call(key, value) ?? false)) {
      failNextKey = null;
      failPutWhen = null;
      throw StateError('Folder write failed');
    }
    await delegate.put(key, value);
  }

  @override
  Future<void> deleteAll(Iterable<dynamic> keys) => delegate.deleteAll(keys);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
