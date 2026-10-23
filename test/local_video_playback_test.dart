import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:kazumi/modules/local_video/local_video.dart';
import 'package:kazumi/pages/history/history_controller.dart';
import 'package:kazumi/pages/player/controller/player_danmaku_controller.dart';
import 'package:kazumi/pages/player/controller/player_playback_controller.dart';
import 'package:kazumi/pages/player/player_controller.dart';
import 'package:kazumi/pages/video/video_controller.dart';
import 'package:kazumi/pages/video/video_playback_args.dart';
import 'package:kazumi/repositories/download_repository.dart';
import 'package:kazumi/repositories/local_video_repository.dart';
import 'package:kazumi/services/download/download_manager.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory storageDirectory;
  late Directory videosDirectory;
  late PathProviderPlatform originalPaths;
  late LocalVideoRepository repository;
  late VideoPageController controller;
  late _Player player;

  setUpAll(() async {
    storageDirectory = await Directory.systemTemp.createTemp(
      'kazumi_local_playback_',
    );
    originalPaths = PathProviderPlatform.instance;
    // Both settings and every GStorage box must be isolated from user data.
    PathProviderPlatform.instance = _TemporaryPaths(storageDirectory.path);
    Hive.init(path.join(storageDirectory.path, 'hive'));
    await GStorage.init();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('window_manager'),
          (_) async => null,
        );
  });

  tearDownAll(() async {
    await Hive.close();
    PathProviderPlatform.instance = originalPaths;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('window_manager'), null);
    await storageDirectory.delete(recursive: true);
  });

  setUp(() async {
    await GStorage.localVideos.clear();
    await GStorage.putSetting(SettingsKeys.privateMode, false);
    await GStorage.putSetting(SettingsKeys.playResume, true);
    await GStorage.putSetting(SettingsKeys.danmakuEnabledByDefault, true);
    videosDirectory = await storageDirectory.createTemp('videos_');
    repository = LocalVideoRepository(GStorage.localVideos);
    // Unused collaborators throw if the local flow enters online/download code.
    controller = VideoPageController(
      _UnusedHistory(),
      _UnusedDownloads(),
      _UnusedDownloadManager(),
      repository,
    );
    player = _Player();
  });

  tearDown(() async {
    controller.dispose();
    await controller.fullscreen.close();
    await GStorage.localVideos.flush();
    await videosDirectory.delete(recursive: true);
  });

  Future<LocalVideo> importVideo(String name) async {
    final file = File(path.join(videosDirectory.path, name));
    await file.parent.create(recursive: true);
    await file.writeAsBytes([0, 1, 2, 3]);
    return (await repository.importFiles([file.path])).added.single;
  }

  void openPlaylist(LocalVideo initial) {
    controller.applyPlaybackArgs(
      LocalVideoPlaybackArgs(
        videos: repository.playlistFor(initial.id),
        initialVideoId: initial.id,
      ),
    );
  }

  Future<void> play(int episode, {int offset = 0}) => controller.changeEpisode(
    episode,
    offset: offset,
    playerController: player,
  );

  test('local subtitle callbacks read fresh settings and expire with playback', () async {
    final first = await importVideo('1.mkv');
    await importVideo('2.mkv');
    openPlaylist(first);
    await play(1);
    final params = player.initializations.single;
    expect(params.nativeSubtitles, isTrue);
    expect(params.canApplySubtitles!(), isTrue);
    expect(params.readSubtitleSettings!(), isNull);
    const settings = LocalSubtitleSettings(source: LocalSubtitleSource.embedded, embeddedTrackId: '2');
    await params.saveSubtitleSettings!(settings);
    expect(params.readSubtitleSettings!()!.toJson(), settings.toJson());
    await play(2);
    expect(params.canApplySubtitles!(), isFalse);
    expect(player.initializations.last.readSubtitleSettings!(), isNull);
  });

  test(
    'local args snapshot natural siblings and select the initial file ID',
    () async {
      await importVideo('Episode 10.mp4');
      final initial = await importVideo('Episode 2.mp4');
      await importVideo('Episode 1.mp4');
      await importVideo(path.join('other', 'Episode 3.mp4'));
      final playlist = repository.playlistFor(initial.id);
      final args = LocalVideoPlaybackArgs(
        videos: playlist,
        initialVideoId: initial.id,
      );
      playlist.clear();

      controller.applyPlaybackArgs(args);

      expect(args.videos.map((video) => video.name), [
        'Episode 1.mp4',
        'Episode 2.mp4',
        'Episode 10.mp4',
      ]);
      expect(() => args.videos.clear(), throwsUnsupportedError);
      expect(
        controller.selectedEpisode,
        const VideoEpisodeSelection(episode: 2, road: 0),
      );
      expect(controller.currentLocalVideo!.id, initial.id);
      expect(
        controller.roadList.single.data,
        args.videos.map((video) => video.id),
      );
      expect(
        controller.roadList.single.identifier,
        args.videos.map((video) => video.name),
      );
      expect(controller.isLocalFileMode, isTrue);
      expect(controller.isOfflineMode, isFalse);
      expect(controller.isFilePlayback, isTrue);
      expect(controller.currentHistoryIdentity, isNull);
      expect(controller.mediaArtwork, isNull);
      expect(controller.mediaAlbum, '本地视频');
      expect(controller.mediaId, initial.id);
      expect(controller.mediaTitle, initial.name);
      expect(controller.loading, isFalse);
      expect(controller.playingEpisode, isNull);
    },
  );

  test(
    'resolveEpisode accepts only existing local positions on road zero',
    () async {
      final first = await importVideo('1.mp4');
      final last = await importVideo('2.mp4');
      openPlaylist(first);

      final resolved = controller.resolveEpisode(
        const VideoEpisodeSelection(episode: 2, road: 0),
      )!;

      expect(resolved.listIndex, 2);
      expect(resolved.displayTitle, last.name);
      expect(resolved.roadIndex, 0);
      expect(resolved.pageUrl, isEmpty);
      expect(resolved.sortNumber, isNull);
      expect(resolved.historyEpisodeNumber, 0);
      expect(resolved.danmakuEpisodeNumber, 0);
      for (final selection in const [
        VideoEpisodeSelection(episode: -1, road: 0),
        VideoEpisodeSelection(episode: 0, road: 0),
        VideoEpisodeSelection(episode: 3, road: 0),
        VideoEpisodeSelection(episode: 1, road: -1),
        VideoEpisodeSelection(episode: 1, road: 1),
      ]) {
        expect(
          controller.resolveEpisode(selection),
          isNull,
          reason: '$selection',
        );
      }
    },
  );

  test(
    'passes an escaped local URI directly to the player without history',
    () async {
      final video = await importVideo('动画 & [测试] # 01.MKV');
      openPlaylist(video);

      await play(1);

      final params = player.initializations.single;
      final uri = Uri.parse(params.videoUrl);
      expect(uri.scheme, 'file');
      expect(uri.fragment, isEmpty);
      expect(uri.toFilePath(windows: true), path.windows.normalize(video.path));
      expect(params.videoUrl, contains('%23'));
      expect(params.videoUrl, contains('%E5%8A%A8'));
      expect(params.isLocalPlayback, isTrue);
      expect(params.bangumiId, 0);
      expect(params.pluginName, isEmpty);
      expect(params.danmakuEpisodeNumber, 0);
      expect(params.pageUrl, isEmpty);
      expect(params.httpHeaders, isEmpty);
      expect(params.adBlockerEnabled, isFalse);
      expect(params.referer, isEmpty);
      expect(params.coverUrl, isNull);
      expect(params.episodeTitle, video.name);
      expect(params.bangumiName, video.name);
      expect(controller.currentHistoryIdentity, isNull);
      expect(
        controller.playingEpisode,
        const VideoEpisodeSelection(episode: 1, road: 0),
      );
      expect(controller.loading, isFalse);
      expect(controller.errorMessage, isNull);
      expect(player.danmaku.requests, isEmpty);
    },
  );

  for (final resume in [true, false]) {
    test('playResume=$resume controls the latest saved local offset', () async {
      final video = await importVideo('1.mp4');
      openPlaylist(video);
      // The route holds an older snapshot; playback must read current storage.
      await repository.saveProgress(
        video.id,
        const Duration(milliseconds: 42789),
        const Duration(minutes: 20),
      );
      await GStorage.putSetting(SettingsKeys.playResume, resume);

      await play(1);

      expect(player.initializations.single.offset, resume ? 42 : 0);
      expect(controller.currentHistoryIdentity, isNull);
    });
  }

  test('an explicit positive offset overrides stored progress', () async {
    final video = await importVideo('1.mp4');
    await repository.saveProgress(
      video.id,
      const Duration(seconds: 42),
      const Duration(minutes: 20),
    );
    await GStorage.putSetting(SettingsKeys.playResume, false);
    openPlaylist(video);

    await play(1, offset: 7);

    expect(player.initializations.single.offset, 7);
  });

  test('a failed player initialization never establishes playback', () async {
    final video = await importVideo('1.mp4');
    openPlaylist(video);
    player.initialize = (_) async => false;

    await play(1);

    expect(controller.playingEpisode, isNull);
    expect(controller.capturePlaybackGuard()(), isFalse);
    expect(player.danmaku.requests, isEmpty);
  });

  test(
    'selected files cannot save progress before successful playback',
    () async {
      final video = await importVideo('1.mp4');
      openPlaylist(video);
      player.playback.playerPosition = const Duration(seconds: 15);
      player.playback.playerDuration = const Duration(minutes: 2);

      await controller.saveLocalProgress(player);

      expect(repository.findById(video.id)!.positionMilliseconds, 0);
      expect(repository.findById(video.id)!.durationMilliseconds, 0);
    },
  );

  test(
    'saves millisecond progress only when private mode is disabled',
    () async {
      final video = await importVideo('1.mp4');
      openPlaylist(video);
      await play(1);
      player.playback.playerPosition = const Duration(milliseconds: 45123);
      player.playback.playerDuration = const Duration(milliseconds: 120456);
      await controller.saveLocalProgress(player);
      expect(repository.findById(video.id)!.positionMilliseconds, 45123);
      expect(repository.findById(video.id)!.durationMilliseconds, 120456);

      await GStorage.putSetting(SettingsKeys.privateMode, true);
      player.playback.playerPosition = const Duration(seconds: 99);
      player.playback.playerDuration = const Duration(minutes: 5);
      await controller.saveLocalProgress(player);

      expect(repository.findById(video.id)!.positionMilliseconds, 45123);
      expect(repository.findById(video.id)!.durationMilliseconds, 120456);
      expect(controller.currentHistoryIdentity, isNull);
    },
  );

  test(
    'switching saves the outgoing file before stop resets the player',
    () async {
      final first = await importVideo('1.mp4');
      final second = await importVideo('2.mp4');
      openPlaylist(first);
      await play(1);
      player.playback.playerPosition = const Duration(milliseconds: 45123);
      player.playback.playerDuration = const Duration(minutes: 20);

      await play(2);

      await GStorage.localVideos.flush();
      expect(repository.findById(first.id)!.positionMilliseconds, 45123);
      expect(repository.findById(first.id)!.durationMilliseconds, 1200000);
      expect(repository.findById(second.id)!.positionMilliseconds, 0);
      expect(controller.currentLocalVideo!.id, second.id);
      expect(player.playback.playerPosition, Duration.zero);
      await play(1);
      expect(player.initializations.last.offset, 45);
    },
  );

  test(
    'missing files retain their record and the next valid item can play',
    () async {
      final missing = await importVideo('1.mp4');
      final existing = await importVideo('2.mp4');
      openPlaylist(missing);
      await File(missing.path).delete();

      await play(1);

      expect(repository.findById(missing.id), isNotNull);
      expect(repository.playlistFor(missing.id), hasLength(2));
      expect(controller.loading, isFalse);
      expect(controller.errorMessage, contains('文件无法访问'));
      expect(controller.playingEpisode, isNull);
      expect(player.initializations, isEmpty);

      await play(2);

      expect(controller.errorMessage, isNull);
      expect(
        controller.playingEpisode,
        const VideoEpisodeSelection(episode: 2, road: 0),
      );
      expect(controller.currentLocalVideo!.id, existing.id);
      expect(repository.findById(missing.id), isNotNull);
      expect(player.initializations, hasLength(1));
    },
  );

  test(
    'A to B to A cannot revive the first A initialization or its guard',
    () async {
      final first = await importVideo('1.mp4');
      await importVideo('2.mp4');
      openPlaylist(first);
      final firstInitialization = Completer<bool>();
      player.initialize = (_) => player.initializations.length == 1
          ? firstInitialization.future
          : Future.value(true);
      final firstPlayback = play(1);
      await _waitUntil(() => player.initializations.length == 1);
      final oldGuard = controller.capturePlaybackGuard();
      expect(oldGuard(), isTrue);

      await play(2);
      final middleGuard = controller.capturePlaybackGuard();
      await play(1);
      final currentGuard = controller.capturePlaybackGuard();
      firstInitialization.complete(true);
      await firstPlayback;

      expect(oldGuard(), isFalse);
      expect(middleGuard(), isFalse);
      expect(currentGuard(), isTrue);
      expect(
        controller.playingEpisode,
        const VideoEpisodeSelection(episode: 1, road: 0),
      );
      expect(player.initializations.map((params) => params.episode), [1, 2, 1]);
    },
  );

  test(
    'exit invalidates pending initialization and prevents later switches',
    () async {
      final video = await importVideo('1.mp4');
      openPlaylist(video);
      final initialized = Completer<bool>();
      player.initialize = (_) => initialized.future;
      final pending = play(1);
      await _waitUntil(() => player.initializations.isNotEmpty);
      final guard = controller.capturePlaybackGuard();

      controller.endPlayback(player);
      initialized.complete(true);
      await pending;
      await play(1);

      expect(guard(), isFalse);
      expect(controller.playingEpisode, isNull);
      expect(player.initializations, hasLength(1));
      expect(player.danmaku.requests, isEmpty);
      expect(repository.findById(video.id)!.positionMilliseconds, 0);
    },
  );

  test(
    'restores only the explicit saved episode ID without sibling inference',
    () async {
      final bound = await importVideo('Anime 第88集.mp4');
      final unbound = await importVideo('Anime 第89集.mp4');
      openPlaylist(bound);
      // Binding after route creation also verifies current repository data wins.
      await repository.setDanmakuBinding(
        bound.id,
        const LocalDanmakuBinding(
          episodeId: 340019,
          animeTitle: 'A different anime title',
          episodeTitle: 'Special 3',
        ),
      );

      await play(1);
      expect(player.danmaku.requests.single.episodeId, 340019);
      player.danmaku.requests.single.result.complete(true);
      await _drainAsync();
      expect(player.danmaku.enabledValues, [true]);

      await play(2);

      expect(controller.currentLocalVideo!.id, unbound.id);
      expect(player.danmaku.requests, hasLength(1));
      expect(repository.findById(unbound.id)!.danmakuBinding, isNull);
      expect(player.initializations.last.danmakuEpisodeNumber, 0);
    },
  );

  test('restoring a binding respects disabled-by-default danmaku', () async {
    final video = await importVideo('1.mp4');
    await repository.setDanmakuBinding(video.id, _binding(101));
    await GStorage.putSetting(SettingsKeys.danmakuEnabledByDefault, false);
    openPlaylist(video);
    await play(1);

    player.danmaku.requests.single.result.complete(true);
    await _drainAsync();

    expect(player.danmaku.appliedEpisodeIds, [101]);
    expect(player.danmaku.enabledValues, [false]);
    expect(controller.capturePlaybackGuard()(), isTrue);
  });

  test(
    'manual cancellation rejects auto danmaku without cancelling playback',
    () async {
      final video = await importVideo('1.mp4');
      await repository.setDanmakuBinding(video.id, _binding(991));
      openPlaylist(video);
      await play(1);
      final request = player.danmaku.requests.single;
      final playbackGuard = controller.capturePlaybackGuard();
      expect(request.canApply!(), isTrue);

      controller.cancelAutomaticDanmakuLoad();
      expect(request.canApply!(), isFalse);
      request.result.complete(true);
      await _drainAsync();

      expect(playbackGuard(), isTrue);
      expect(
        controller.playingEpisode,
        const VideoEpisodeSelection(episode: 1, road: 0),
      );
      expect(player.danmaku.appliedEpisodeIds, isEmpty);
      expect(player.danmaku.enabledValues, isEmpty);
      expect(player.stopCount, 1);
    },
  );

  test(
    'a late old danmaku result cannot replace the next file binding',
    () async {
      final first = await importVideo('1.mp4');
      final second = await importVideo('2.mp4');
      await repository.setDanmakuBinding(first.id, _binding(101));
      await repository.setDanmakuBinding(second.id, _binding(205));
      openPlaylist(first);
      await play(1);
      final oldRequest = player.danmaku.requests.single;

      await play(2);
      final currentRequest = player.danmaku.requests.last;
      currentRequest.result.complete(true);
      await _drainAsync();
      oldRequest.result.complete(true);
      await _drainAsync();

      expect(player.danmaku.requests.map((request) => request.episodeId), [
        101,
        205,
      ]);
      expect(oldRequest.canApply!(), isFalse);
      expect(currentRequest.canApply!(), isTrue);
      expect(player.danmaku.appliedEpisodeIds, [205]);
      expect(player.danmaku.enabledValues, [true]);
      expect(controller.currentLocalVideo!.id, second.id);
    },
  );

  test(
    'exit saves once and rejects the pending automatic danmaku result',
    () async {
      final video = await importVideo('1.mp4');
      await repository.setDanmakuBinding(video.id, _binding(101));
      openPlaylist(video);
      await play(1);
      final request = player.danmaku.requests.single;
      final guard = controller.capturePlaybackGuard();
      player.playback.playerPosition = const Duration(milliseconds: 12345);
      player.playback.playerDuration = const Duration(minutes: 2);

      controller.endPlayback(player);
      player.playback.playerPosition = const Duration(seconds: 99);
      controller.endPlayback(player);
      request.result.complete(true);
      await _drainAsync();
      await GStorage.localVideos.flush();

      expect(guard(), isFalse);
      expect(request.canApply!(), isFalse);
      expect(player.danmaku.cancelCount, 1);
      expect(player.danmaku.appliedEpisodeIds, isEmpty);
      expect(player.danmaku.enabledValues, isEmpty);
      expect(repository.findById(video.id)!.positionMilliseconds, 12345);
      expect(repository.findById(video.id)!.durationMilliseconds, 120000);
    },
  );

  test(
    'failed automatic danmaku leaves playback running and switchable',
    () async {
      final first = await importVideo('1.mp4');
      final second = await importVideo('2.mp4');
      await repository.setDanmakuBinding(first.id, _binding(101));
      openPlaylist(first);
      await play(1);

      player.danmaku.requests.single.result.completeError(
        StateError('fixture danmaku service unavailable'),
      );
      await _drainAsync();

      expect(controller.capturePlaybackGuard()(), isTrue);
      expect(controller.errorMessage, isNull);
      expect(
        controller.playingEpisode,
        const VideoEpisodeSelection(episode: 1, road: 0),
      );
      expect(player.stopCount, 1);
      expect(player.danmaku.enabledValues, isEmpty);
      await play(2);
      expect(controller.currentLocalVideo!.id, second.id);
      expect(player.initializations, hasLength(2));
    },
  );
}

LocalDanmakuBinding _binding(int episodeId) => LocalDanmakuBinding(
  episodeId: episodeId,
  animeTitle: 'Fixture anime',
  episodeTitle: 'Fixture episode',
);

Future<void> _drainAsync() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

Future<void> _waitUntil(bool Function() condition) async {
  for (var attempt = 0; attempt < 500; attempt++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('Timed out waiting for the player initialization boundary');
}

class _TemporaryPaths extends PathProviderPlatform {
  _TemporaryPaths(this.directory);

  final String directory;

  @override
  Future<String> getApplicationSupportPath() async => directory;

  @override
  Future<String> getApplicationDocumentsPath() async => directory;

  @override
  Future<String> getTemporaryPath() async => directory;

  @override
  Future<String> getApplicationCachePath() async => directory;
}

class _UnusedHistory extends Fake implements HistoryController {}

class _UnusedDownloads extends Fake implements IDownloadRepository {}

class _UnusedDownloadManager extends Fake implements IDownloadManager {}

// No constructor or method here invokes MediaKit, audio or a native plugin.
class _Player extends Fake implements PlayerController {
  @override
  final _Danmaku danmaku = _Danmaku();

  @override
  final _Playback playback = _Playback();

  final initializations = <PlaybackInitParams>[];
  Future<bool> Function(PlaybackInitParams)? initialize;
  int stopCount = 0;

  @override
  Future<bool> init(PlaybackInitParams params) async {
    initializations.add(params);
    return initialize == null ? true : await initialize!(params);
  }

  @override
  Future<void> stop() async {
    stopCount++;
    playback.playerPosition = Duration.zero;
    playback.playerDuration = Duration.zero;
  }
}

class _Playback extends Fake implements PlayerPlaybackController {
  @override
  Duration playerPosition = Duration.zero;

  @override
  Duration playerDuration = Duration.zero;
}

class _DanmakuRequest {
  _DanmakuRequest(this.episodeId, this.canApply);

  final int episodeId;
  final DanmakuApplyGuard? canApply;
  final result = Completer<bool?>();
}

class _Danmaku extends Fake implements PlayerDanmakuController {
  final requests = <_DanmakuRequest>[];
  final enabledValues = <bool>[];
  final appliedEpisodeIds = <int>[];
  int cancelCount = 0;

  @override
  void finishDanmakuLoad({bool disableDanmaku = false}) {}

  @override
  void clearAndInvalidateScheduledDanmakus() {}

  @override
  void cancelEpisodeDanmakuLoad() {
    cancelCount++;
  }

  @override
  void setDanmakuEnabled(bool value) {
    enabledValues.add(value);
  }

  @override
  Future<bool?> getDanDanmakuByEpisodeID(
    int episodeID, {
    DanmakuApplyGuard? canApply,
  }) async {
    final request = _DanmakuRequest(episodeID, canApply);
    requests.add(request);
    final result = await request.result.future;
    if (canApply != null && !canApply()) return null;
    if (result == true) appliedEpisodeIds.add(episodeID);
    return result;
  }
}
