import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:kazumi/modules/local_video/local_video.dart';
import 'package:kazumi/repositories/local_video_repository.dart';
import 'package:path/path.dart' as path;

void main() {
  late Directory tempDirectory;
  late Directory videosDirectory;
  late Box<String> box;
  late Box<String> foldersBox;
  late LocalVideoRepository repository;

  setUp(() async {
    tempDirectory = await Directory.systemTemp.createTemp(
      'kazumi_local_video_',
    );
    videosDirectory = await Directory(
      path.join(tempDirectory.path, 'videos'),
    ).create();
    Hive.init(path.join(tempDirectory.path, 'hive'));
    box = await Hive.openBox<String>('local_videos');
    foldersBox = await Hive.openBox<String>('local_video_folders');
    repository = LocalVideoRepository(box, foldersBox: foldersBox);
  });

  tearDown(() async {
    await Hive.close();
    if (await tempDirectory.exists()) {
      await tempDirectory.delete(recursive: true);
    }
  });

  Future<File> createVideo(String name, {Directory? directory}) async {
    final file = File(path.join((directory ?? videosDirectory).path, name));
    await file.parent.create(recursive: true);
    return file.writeAsBytes([0, 1, 2, 3]);
  }

  test(
    'imports the original absolute path under a fixed length safe Hive key',
    () async {
      final file = await createVideo('动画 & [测试] # 01.MKV');

      final result = await repository.importFiles([file.path]);

      expect(result.added, hasLength(1));
      expect(result.failedPaths, isEmpty);
      expect(result.duplicateCount, 0);
      expect(result.unsupportedCount, 0);
      final video = result.added.single;
      expect(video.id, matches(RegExp(r'^[a-f0-9]{64}$')));
      expect(video.path, path.normalize(file.absolute.path));
      expect(video.name, path.basename(file.path));
      expect(repository.findById(video.id)!.toJson(), video.toJson());
      expect(jsonDecode(box.get(video.id)!), video.toJson());
      expect(await file.readAsBytes(), [0, 1, 2, 3]);
    },
  );

  test(
    'deduplicates normalized path variants without losing metadata',
    () async {
      final file = await createVideo('Episode 01.mp4');
      final video = (await repository.importFiles([file.path])).added.single;
      const binding = LocalDanmakuBinding(
        episodeId: 1,
        animeTitle: 'Anime',
        episodeTitle: 'EP1',
      );
      await repository.saveProgress(
        video.id,
        const Duration(seconds: 30),
        const Duration(minutes: 24),
      );
      await repository.setDanmakuBinding(video.id, binding);
      final dotPath = path.join(
        file.parent.path,
        '.',
        'unused',
        '..',
        path.basename(file.path),
      );
      final variant = Platform.isWindows
          ? file.path.toUpperCase().replaceAll(r'\', '/')
          : file.path;

      final result = await repository.importFiles([dotPath, variant]);

      expect(result.added, isEmpty);
      expect(result.duplicateCount, 2);
      expect(repository.videos, hasLength(1));
      final saved = repository.findById(video.id)!;
      expect(saved.positionMilliseconds, 30000);
      expect(saved.durationMilliseconds, 1440000);
      expect(saved.danmakuBinding!.toJson(), binding.toJson());
      expect(saved.path, video.path);
    },
  );

  test('reports a missing file while retaining valid imports', () async {
    final valid = await createVideo('good.mp4');
    final missing = path.join(videosDirectory.path, 'missing.mkv');

    final result = await repository.importFiles([missing, valid.path]);

    expect(result.failedPaths, [missing]);
    expect(result.added.single.path, valid.path);
    expect(repository.videos, hasLength(1));
  });

  test(
    'scans nested folders once and filters all supported video extensions',
    () async {
      const extensions = [
        'mp4',
        'mkv',
        'avi',
        'mov',
        'webm',
        'flv',
        'wmv',
        'm4v',
        'ts',
        'm2ts',
        'mpg',
        'mpeg',
      ];
      for (var i = 0; i < extensions.length; i++) {
        await createVideo(
          path.join('series', 'season', '$i.${extensions[i].toUpperCase()}'),
        );
      }
      await createVideo('notes.txt');
      await createVideo('cover.jpg');

      final result = await repository.importDirectory(videosDirectory.path);
      await createVideo('later.mp4');

      expect(result.added, hasLength(extensions.length));
      expect(result.unsupportedCount, 2);
      expect(result.failedPaths, isEmpty);
      expect(repository.videos, hasLength(extensions.length));
    },
  );

  test('reports a missing folder instead of throwing', () async {
    final missing = path.join(videosDirectory.path, 'missing');

    final result = await repository.importDirectory(missing);

    expect(result.added, isEmpty);
    expect(result.failedPaths, [missing]);
  });

  test('retains valid siblings when a subtree cannot be listed', () async {
    final readable = await createVideo('readable.mp4');
    final blocked = await Directory(
      path.join(videosDirectory.path, 'blocked'),
    ).create();
    await createVideo('hidden.mp4', directory: blocked);

    final result = await IOOverrides.runWithIOOverrides(
      () => repository.importDirectory(videosDirectory.path),
      _ReadFailureOverrides(blockedDirectory: blocked.path),
    );

    expect(result.added.single.path, readable.path);
    expect(result.failedPaths, [blocked.path]);
  });

  test(
    'reports an unreadable file while importing its readable sibling',
    () async {
      final blocked = await createVideo('unreadable.mp4');
      final readable = await createVideo('readable.mp4');

      final result = await IOOverrides.runWithIOOverrides(
        () => repository.importFiles([blocked.path, readable.path]),
        _ReadFailureOverrides(blockedFile: blocked.path),
      );

      expect(result.added.single.path, readable.path);
      expect(result.failedPaths, [blocked.path]);
    },
  );

  test('does not follow folder links during recursive scanning', () async {
    final externalDirectory = await Directory(
      path.join(tempDirectory.path, 'external'),
    ).create();
    await createVideo('external.mp4', directory: externalDirectory);
    final link = Link(path.join(videosDirectory.path, 'linked'));
    try {
      await link.create(externalDirectory.path);
    } on FileSystemException {
      markTestSkipped(
        'Creating links requires OS support or Windows developer mode.',
      );
      return;
    }
    final ownFile = await createVideo('own.mp4');

    final result = await repository.importDirectory(videosDirectory.path);
    final linkedRootResult = await repository.importDirectory(link.path);

    expect(result.added.single.path, ownFile.path);
    expect(result.failedPaths, isEmpty);
    expect(linkedRootResult.added, isEmpty);
    expect(linkedRootResult.failedPaths, [link.path]);
  });

  test(
    'groups only the direct parent directory and sorts natural episode numbers',
    () async {
      final files = <File>[];
      for (final name in [
        'Episode 10.mp4',
        'Episode 2.mp4',
        'Episode 1.mp4',
        'Episode 02.mp4',
      ]) {
        files.add(await createVideo(name));
      }
      final nested = await createVideo(path.join('nested', 'Episode 3.mp4'));
      await repository.importFiles([
        ...files.map((file) => file.path),
        nested.path,
      ]);
      final id = repository.videos
          .firstWhere((video) => video.path == files.first.path)
          .id;

      final playlist = repository.playlistFor(id);

      expect(playlist.map((video) => video.name), [
        'Episode 1.mp4',
        'Episode 02.mp4',
        'Episode 2.mp4',
        'Episode 10.mp4',
      ]);
      expect(repository.playlistFor('missing'), isEmpty);
      expect(
        repository.playlistFor(
          repository.videos.firstWhere((video) => video.path == nested.path).id,
        ),
        hasLength(1),
      );
    },
  );

  test(
    'persists progress and per-file bindings across reopening Hive',
    () async {
      final first = await createVideo('1.mp4');
      final second = await createVideo('2.mp4');
      final added = (await repository.importFiles([
        first.path,
        second.path,
      ])).added;
      const firstBinding = LocalDanmakuBinding(
        episodeId: 11,
        animeTitle: 'A',
        episodeTitle: '1',
      );
      const secondBinding = LocalDanmakuBinding(
        episodeId: 12,
        animeTitle: 'A',
        episodeTitle: '2',
      );
      await repository.setDanmakuBinding(added[0].id, firstBinding);
      await repository.setDanmakuBinding(added[1].id, secondBinding);
      await repository.saveProgress(
        added[0].id,
        const Duration(milliseconds: 12345),
        const Duration(minutes: 20),
      );

      await box.close();
      box = await Hive.openBox<String>('local_videos');
      foldersBox = await Hive.openBox<String>('local_video_folders');
      repository = LocalVideoRepository(box, foldersBox: foldersBox);

      expect(repository.findById(added[0].id)!.positionMilliseconds, 12345);
      expect(repository.findById(added[0].id)!.durationMilliseconds, 1200000);
      expect(
        repository.findById(added[0].id)!.danmakuBinding!.toJson(),
        firstBinding.toJson(),
      );
      expect(
        repository.findById(added[1].id)!.danmakuBinding!.toJson(),
        secondBinding.toJson(),
      );
      expect(repository.findById(added[1].id)!.positionMilliseconds, 0);

      await repository.setDanmakuBinding(added[0].id, null);

      expect(repository.findById(added[0].id)!.danmakuBinding, isNull);
      expect(repository.findById(added[1].id)!.danmakuBinding!.episodeId, 12);
    },
  );

  test('removes only library metadata and retains the original file', () async {
    final file = await createVideo('keep.mp4');
    final video = (await repository.importFiles([file.path])).added.single;

    await repository.remove(video.id);

    expect(repository.videos, isEmpty);
    expect(repository.findById(video.id), isNull);
    expect(await file.exists(), isTrue);
    expect(await file.readAsBytes(), [0, 1, 2, 3]);
  });

  test(
    'subtitle updates preserve fresh progress and danmaku metadata',
    () async {
      final file = await createVideo('subtitles.mkv');
      final video = (await repository.importFiles([file.path])).added.single;
      const settings = LocalSubtitleSettings(
        source: LocalSubtitleSource.external,
        externalPath: r'C:\字幕\中文 & English.ass',
      );
      const binding = LocalDanmakuBinding(
        episodeId: 42,
        animeTitle: 'Anime',
        episodeTitle: 'Episode 1',
      );
      await repository.saveProgress(
        video.id,
        const Duration(seconds: 2),
        const Duration(seconds: 10),
      );
      await repository.setDanmakuBinding(video.id, binding);
      await repository.setSubtitleSettings(video.id, settings);

      var saved = repository.findById(video.id)!;
      expect(saved.positionMilliseconds, 2000);
      expect(saved.durationMilliseconds, 10000);
      expect(saved.danmakuBinding!.toJson(), binding.toJson());
      expect(saved.subtitleSettings!.toJson(), settings.toJson());

      await repository.saveProgress(
        video.id,
        const Duration(seconds: 4),
        const Duration(seconds: 12),
      );
      await repository.setDanmakuBinding(video.id, null);
      saved = repository.findById(video.id)!;
      expect(saved.subtitleSettings!.toJson(), settings.toJson());

      await repository.setSubtitleSettings(
        video.id,
        settings.copyWith(enabled: false),
      );
      saved = repository.findById(video.id)!;
      expect(saved.positionMilliseconds, 4000);
      expect(saved.durationMilliseconds, 12000);
      expect(saved.danmakuBinding, isNull);
      expect(saved.subtitleSettings!.enabled, isFalse);
      expect(saved.subtitleSettings!.externalPath, settings.externalPath);
    },
  );

  test('keeps per-video subtitles independent across reopening Hive', () async {
    final first = await createVideo('first.mkv');
    final second = await createVideo('second.mkv');
    final added = (await repository.importFiles([
      first.path,
      second.path,
    ])).added;
    const firstSettings = LocalSubtitleSettings(
      enabled: false,
      source: LocalSubtitleSource.embedded,
      embeddedTrackId: '2',
    );
    const secondSettings = LocalSubtitleSettings(
      source: LocalSubtitleSource.external,
      externalPath: r'C:\字幕\second.srt',
    );
    await repository.setSubtitleSettings(added[0].id, firstSettings);
    await repository.setSubtitleSettings(added[1].id, secondSettings);

    await box.close();
    box = await Hive.openBox<String>('local_videos');
    foldersBox = await Hive.openBox<String>('local_video_folders');
    repository = LocalVideoRepository(box, foldersBox: foldersBox);

    expect(
      repository.findById(added[0].id)!.subtitleSettings!.toJson(),
      firstSettings.toJson(),
    );
    expect(
      repository.findById(added[1].id)!.subtitleSettings!.toJson(),
      secondSettings.toJson(),
    );

    await repository.setSubtitleSettings(added[0].id, null);
    expect(repository.findById(added[0].id)!.subtitleSettings, isNull);
    expect(
      repository.findById(added[1].id)!.subtitleSettings!.toJson(),
      secondSettings.toJson(),
    );
  });

  test('subtitle updates do not recreate a removed record', () async {
    final file = await createVideo('removed.mkv');
    final video = (await repository.importFiles([file.path])).added.single;
    await repository.remove(video.id);

    await repository.setSubtitleSettings(
      video.id,
      const LocalSubtitleSettings(),
    );
    await repository.setSubtitleSettings(video.id, null);

    expect(repository.findById(video.id), isNull);
    expect(repository.videos, isEmpty);
  });

  test('does not recreate missing records when saving player state', () async {
    await repository.saveProgress(
      'missing',
      const Duration(seconds: 2),
      const Duration(seconds: 10),
    );
    await repository.setDanmakuBinding('missing', null);
    await repository.setSubtitleSettings('missing', null);
    await repository.remove('missing');

    expect(repository.videos, isEmpty);
  });
}

// Simulate OS permission failures without changing real files' access controls.
final class _ReadFailureOverrides extends IOOverrides {
  _ReadFailureOverrides({this.blockedDirectory, this.blockedFile});

  final String? blockedDirectory;
  final String? blockedFile;

  @override
  Directory createDirectory(String path) =>
      _DirectoryReadFailure(super.createDirectory(path), blockedDirectory);

  @override
  File createFile(String path) => path == blockedFile
      ? _FileReadFailure(super.createFile(path))
      : super.createFile(path);
}

class _DirectoryReadFailure implements Directory {
  _DirectoryReadFailure(this.directory, this.blockedPath);

  final Directory directory;
  final String? blockedPath;

  @override
  String get path => directory.path;

  @override
  Directory get absolute =>
      _DirectoryReadFailure(directory.absolute, blockedPath);

  @override
  Future<bool> exists() => directory.exists();

  @override
  Stream<FileSystemEntity> list({
    bool recursive = false,
    bool followLinks = true,
  }) {
    if (path == blockedPath) {
      return Stream.error(FileSystemException('Access denied', path));
    }
    return directory
        .list(recursive: recursive, followLinks: followLinks)
        .map(
          (entity) => entity is Directory
              ? _DirectoryReadFailure(entity, blockedPath)
              : entity,
        );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FileReadFailure implements File {
  _FileReadFailure(this.file);

  final File file;

  @override
  String get path => file.path;

  @override
  File get absolute => this;

  @override
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) async {
    throw FileSystemException('Access denied', path);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
