import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:kazumi/modules/local_video/local_video.dart';
import 'package:kazumi/navigation.dart';
import 'package:kazumi/pages/download/download_controller.dart';
import 'package:kazumi/pages/history/history_controller.dart';
import 'package:kazumi/pages/my/my_controller.dart';
import 'package:kazumi/pages/player/player_controller.dart';
import 'package:kazumi/pages/player/player_item.dart';
import 'package:kazumi/pages/video/video_controller.dart';
import 'package:kazumi/pages/video/video_playback_args.dart';
import 'package:kazumi/repositories/download_repository.dart';
import 'package:kazumi/repositories/local_video_repository.dart';
import 'package:kazumi/services/download/download_manager.dart';
import 'package:kazumi/services/player/audio_controller.dart';
import 'package:kazumi/services/shaders/shader_asset_service.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temporary;
  late PathProviderPlatform originalPaths;
  late ModularBootstrap bootstrap;

  setUpAll(() async {
    temporary = await Directory.systemTemp.createTemp('kazumi_autoplay_');
    originalPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(temporary.path);
    Hive.init(p.join(temporary.path, 'hive'));
    await GStorage.init();
    await GStorage.putSetting(SettingsKeys.webDavEnable, false);
    await GStorage.putSetting(SettingsKeys.danmakuEnabledByDefault, false);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('window_manager'),
          (_) async => null,
        );
    bootstrap = bootstrapModule(
      createModule(
        register: (c) {
          c.addSingleton<HistoryController>(() => _History());
          c.addSingleton<MyController>(() => _My());
        },
      ),
    );
  });

  tearDownAll(() async {
    bootstrap.injector.dispose();
    await Hive.close();
    PathProviderPlatform.instance = originalPaths;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('window_manager'), null);
    await temporary.delete(recursive: true);
  });

  test('automatic next episode is enabled by default', () {
    expect(GStorage.getSetting(SettingsKeys.autoPlayNext), isTrue);
  });

  for (final scenario in [
    (enabled: true, initial: 2, advances: true),
    (enabled: false, initial: 2, advances: false),
    (enabled: true, initial: 3, advances: false),
  ]) {
    testWidgets(
      'completion enabled=${scenario.enabled} at ${scenario.initial} advances=${scenario.advances}',
      (tester) async {
        late VideoPageController controller;
        late _Player player;
        final changed = <int>[];
        await tester.runAsync(() async {
          await GStorage.putSetting(
            SettingsKeys.autoPlayNext,
            scenario.enabled,
          );
          final repository = LocalVideoRepository(
            _MemoryBox(),
            foldersBox: _MemoryBox(),
          );
          final directory = await temporary.createTemp('media_');
          final videos = <LocalVideo>[];
          for (final name in ['10.mp4', '2.mp4', '1.mp4']) {
            final file = await File(
              p.join(directory.path, name),
            ).writeAsBytes([0, 1, 2, 3]);
            videos.add(
              (await repository.importFiles([file.path])).added.single,
            );
          }
          final category = await repository.createVirtualFolder('当前文件夹');
          await repository.addVideosToFolder(
            category.id,
            videos.map((v) => v.id),
          );
          final child = await repository.createVirtualFolder(
            '子文件夹',
            parentId: category.id,
          );
          final other = await File(
            p.join(directory.path, 'other.mp4'),
          ).writeAsBytes([0, 1]);
          final otherVideo = (await repository.importFiles([
            other.path,
          ])).added.single;
          await repository.addVideosToFolder(child.id, [otherVideo.id]);
          final playlist = repository.videosIn(category.id);
          controller = VideoPageController(
            _History(),
            _Downloads(),
            _Manager(),
            repository,
          );
          controller.applyPlaybackArgs(
            LocalVideoPlaybackArgs(
              videos: playlist,
              initialVideoId: playlist[scenario.initial - 1].id,
            ),
          );
          player = _Player();
          await controller.changeEpisode(
            scenario.initial,
            playerController: player,
          );
        });
        final focus = FocusNode();
        await tester.pumpWidget(
          MaterialApp(
            scaffoldMessengerKey: rootScaffoldMessengerKey,
            home: Scaffold(
              body: PlayerItem(
                playerController: player,
                videoPageController: controller,
                fillsWindow: false,
                changeEpisode: (episode, {currentRoad = 0, offset = 0}) async {
                  changed.add(episode);
                  await controller.changeEpisode(
                    episode,
                    currentRoad: currentRoad,
                    offset: offset,
                    playerController: player,
                  );
                },
                onBackPressed: () {},
                keyboardFocus: focus,
                pauseForTimedShutdown: () {},
              ),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 350));
        expect(tester.takeException(), isNull);
        player.playback.completed = true;
        player.playback.playing = false;
        await tester.pump(const Duration(seconds: 1));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump();
        expect(changed, scenario.advances ? [3] : isEmpty);
        expect(
          controller.currentLocalVideo!.name,
          scenario.advances || scenario.initial == 3 ? '10.mp4' : '2.mp4',
        );
        expect(controller.roadList.single.identifier, [
          '1.mp4',
          '2.mp4',
          '10.mp4',
        ]);
        await tester.pump(const Duration(seconds: 2));
        expect(
          changed,
          scenario.advances ? [3] : isEmpty,
          reason: 'completion neither repeats a transition nor wraps the list',
        );
        await tester.pumpWidget(const SizedBox.shrink());
        focus.dispose();
        await tester.runAsync(() async {
          controller.dispose();
          await controller.fullscreen.close();
          player.dispose();
        });
        expect(tester.takeException(), isNull);
      },
    );
  }
}

class _Paths extends PathProviderPlatform {
  _Paths(this.directory);
  final String directory;
  @override
  Future<String> getApplicationSupportPath() async => directory;
}

class _History extends Fake implements HistoryController {}

class _My extends Fake implements MyController {}

class _Downloads extends Fake implements IDownloadRepository {}

class _Manager extends Fake implements IDownloadManager {}

class _DownloadController extends Fake implements DownloadController {}

class _Shaders extends Fake implements ShaderAssetService {}

class _Audio extends Fake implements AudioController {
  @override
  dynamic noSuchMethod(Invocation invocation) => Future<void>.value();
}

// Keep the real playback/panel/danmaku controllers and PlayerItem completion
// timer; replace only native media initialization and OS audio integration.
class _Player extends PlayerController {
  _Player() : super(_Shaders(), _DownloadController(), _Audio());
  @override
  Future<bool> init(PlaybackInitParams params) async {
    videoUrl = params.videoUrl;
    isLocalPlayback = params.isLocalPlayback;
    bangumiId = params.bangumiId;
    currentEpisode = params.episode;
    currentRoad = params.currentRoad;
    currentDanmakuEpisodeNumber = params.danmakuEpisodeNumber;
    referer = params.referer;
    playback.resetForInit();
    playback.loading = false;
    playback.isBuffering = false;
    playback.playing = true;
    playback.duration = const Duration(seconds: 2);
    return true;
  }
}

class _MemoryBox extends Fake implements Box<String> {
  final _values = <dynamic, String>{};
  @override
  Iterable<String> get values => _values.values;
  @override
  String? get(dynamic key, {String? defaultValue}) =>
      _values[key] ?? defaultValue;
  @override
  bool containsKey(dynamic key) => _values.containsKey(key);
  @override
  Future<void> put(dynamic key, String value) async {
    _values[key] = value;
  }

  @override
  Future<void> delete(dynamic key) async {
    _values.remove(key);
  }
}
