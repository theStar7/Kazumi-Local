import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/modules/danmaku/danmaku_episode_response.dart';
import 'package:kazumi/modules/danmaku/danmaku_search_response.dart';
import 'package:kazumi/modules/local_video/local_video.dart';
import 'package:kazumi/navigation.dart';
import 'package:kazumi/pages/player/controller/player_danmaku_controller.dart';
import 'package:kazumi/pages/player/danmaku_source_sheet.dart';
import 'package:kazumi/request/core/network_exception.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

const _anime = DanmakuSearchAnime(
  animeId: 42,
  animeTitle: 'Fixture anime',
  typeDescription: 'TV',
);
const _searchResult = DanmakuSearchResponse(animes: [_anime], hasMore: false);
const _episodeTitle = 'Fixture episode';

DanmakuEpisodeResponse _episodeResult() => DanmakuEpisodeResponse(
  bangumiId: _anime.animeId,
  episodes: [DanmakuEpisode(episodeId: 42003, episodeTitle: _episodeTitle)],
  errorCode: 0,
  success: true,
  errorMessage: '',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temporary;
  late PathProviderPlatform originalPaths;
  late _Danmaku danmaku;
  late bool canApply;
  late int beforeApplyCount;
  late List<LocalDanmakuBinding> selected;

  setUpAll(() async {
    temporary = await Directory.systemTemp.createTemp('kazumi_source_session_');
    originalPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _TemporaryPaths(temporary.path);
    Hive.init(path.join(temporary.path, 'hive'));
    await GStorage.init();
    // No settings writes run under a widget test's fake clock.
    await GStorage.putSetting(SettingsKeys.privateMode, true);
  });

  tearDownAll(() async {
    await Hive.close();
    PathProviderPlatform.instance = originalPaths;
    await temporary.delete(recursive: true);
  });

  setUp(() {
    danmaku = _Danmaku();
    canApply = true;
    beforeApplyCount = 0;
    selected = [];
  });

  Future<void> openSheet(
    WidgetTester tester, {
    Future<DanmakuSearchResponse> Function(String)? search,
    Future<DanmakuEpisodeResponse> Function(int)? episodes,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: rootNavigatorKey,
        scaffoldMessengerKey: rootScaffoldMessengerKey,
        navigatorObservers: [KazumiDialog.observer],
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => unawaited(
                showDanmakuSourceSheet(
                  context,
                  bangumiId: 0,
                  initialKeyword: 'Fixture keyword',
                  localRecordId: 'fixture-local-file',
                  danmakuController: danmaku,
                  onBeforeApply: () => beforeApplyCount++,
                  canApply: () => canApply,
                  onSelected: (binding) async => selected.add(binding),
                  searchAnimes: search ?? (_) async => _searchResult,
                  loadEpisodes: episodes ?? (_) async => _episodeResult(),
                ),
              ),
              child: const Text('Open sources'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open sources'));
    await tester.pumpAndSettle();
    expect(find.text('选择弹幕源'), findsOneWidget);
  }

  Future<void> showEpisodes(WidgetTester tester) async {
    await tester.tap(find.text('搜索'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(_anime.animeTitle));
    await tester.pumpAndSettle();
    expect(find.text(_episodeTitle), findsOneWidget);
  }

  void expectClosedWithoutSelection() {
    expect(KazumiDialog.observer.hasKazumiDialog, isFalse);
    expect(find.text('选择分集'), findsNothing);
    expect(find.text('切换中…'), findsNothing);
    expect(selected, isEmpty);
    expect(danmaku.enabled, isEmpty);
  }

  testWidgets('stale playback closes a pending source switch returning null', (
    tester,
  ) async {
    await openSheet(tester);
    await showEpisodes(tester);
    await tester.tap(find.text(_episodeTitle));
    await tester.pump();
    expect(find.text('切换中…'), findsOneWidget);
    expect(danmaku.episodeIds, [42003]);
    expect(danmaku.guards.single!(), isTrue);

    canApply = false;
    danmaku.pending.single.complete(null);
    await tester.pumpAndSettle();

    expect(danmaku.guards.single!(), isFalse);
    expectClosedWithoutSelection();
    expect(beforeApplyCount, 1);
  });

  testWidgets(
    'search shows missing build credentials as a configuration error',
    (tester) async {
      const message =
          '未配置弹弹play API凭据，请配置 DANDANAPI_APPID 和 DANDANAPI_KEY 后重新编译';
      await openSheet(
        tester,
        search: (_) async => throw const NetworkException(
          type: NetworkExceptionType.unknown,
          message: message,
        ),
      );
      await tester.tap(find.text('搜索'));
      await tester.pumpAndSettle();

      expect(find.text(message), findsOneWidget);
      expect(find.text('未找到番剧'), findsNothing);
      expect(selected, isEmpty);
      KazumiDialog.dismiss();
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'a source fetch shows its network error without saving a binding',
    (tester) async {
      const message = '弹弹play API 鉴权失败（HTTP 403）';
      await openSheet(tester);
      await showEpisodes(tester);
      await tester.tap(find.text(_episodeTitle));
      await tester.pump();
      danmaku.pending.single.completeError(
        const NetworkException(
          type: NetworkExceptionType.badResponse,
          message: message,
          statusCode: 403,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text(message), findsOneWidget);
      expect(selected, isEmpty);
      expect(danmaku.enabled, isEmpty);
      KazumiDialog.dismiss();
      await tester.pumpAndSettle();
    },
  );

  testWidgets('an expired session before selection closes without fetching', (
    tester,
  ) async {
    await openSheet(tester);
    await showEpisodes(tester);
    canApply = false;

    await tester.tap(find.text(_episodeTitle));
    await tester.pumpAndSettle();

    expectClosedWithoutSelection();
    expect(danmaku.episodeIds, isEmpty);
    expect(beforeApplyCount, 0);
  });

  testWidgets('search completion closes a sheet owned by an expired session', (
    tester,
  ) async {
    final response = Completer<DanmakuSearchResponse>();
    await openSheet(tester, search: (_) => response.future);
    await tester.tap(find.text('搜索'));
    await tester.pump();
    expect(find.text('搜索中…'), findsOneWidget);

    canApply = false;
    response.complete(_searchResult);
    await tester.pumpAndSettle();

    expectClosedWithoutSelection();
    expect(find.text('选择番剧'), findsNothing);
    expect(danmaku.episodeIds, isEmpty);
  });

  testWidgets('episode-list completion closes an expired session', (
    tester,
  ) async {
    final response = Completer<DanmakuEpisodeResponse>();
    await openSheet(tester, episodes: (_) => response.future);
    await tester.tap(find.text('搜索'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(_anime.animeTitle));
    await tester.pump();
    expect(find.text('加载分集…'), findsOneWidget);

    canApply = false;
    response.complete(_episodeResult());
    await tester.pumpAndSettle();

    expectClosedWithoutSelection();
    expect(danmaku.episodeIds, isEmpty);
  });

  testWidgets(
    'a null result with an active session leaves selection retryable',
    (tester) async {
      await openSheet(tester);
      await showEpisodes(tester);
      await tester.tap(find.text(_episodeTitle));
      await tester.pump();
      danmaku.pending.single.complete(null);
      await tester.pumpAndSettle();

      expect(KazumiDialog.observer.hasKazumiDialog, isTrue);
      expect(find.text('切换中…'), findsNothing);
      expect(find.text(_episodeTitle), findsOneWidget);
      expect(selected, isEmpty);
      await tester.tap(find.text(_episodeTitle));
      await tester.pump();
      expect(danmaku.episodeIds, [42003, 42003]);
      danmaku.pending.last.complete(false);
      await tester.pumpAndSettle();
      expect(KazumiDialog.observer.hasKazumiDialog, isFalse);
      expect(selected.single.episodeId, 42003);
    },
  );

  testWidgets(
    'a failed fetch leaves no binding and permits another selection',
    (tester) async {
      await openSheet(tester);
      await showEpisodes(tester);
      await tester.tap(find.text(_episodeTitle));
      await tester.pump();
      danmaku.pending.single.completeError(StateError('fixture fetch failure'));
      await tester.pumpAndSettle();

      expect(KazumiDialog.observer.hasKazumiDialog, isTrue);
      expect(find.text('切换中…'), findsNothing);
      expect(find.text(_episodeTitle), findsOneWidget);
      expect(find.text('弹幕源切换失败'), findsOneWidget);
      expect(selected, isEmpty);
      expect(danmaku.enabled, isEmpty);
      KazumiDialog.dismiss();
      await tester.pumpAndSettle();
    },
  );

  for (final hasDanmakus in [true, false]) {
    testWidgets('successful fetch ($hasDanmakus) commits the precise binding', (
      tester,
    ) async {
      await openSheet(tester);
      await showEpisodes(tester);
      await tester.tap(find.text(_episodeTitle));
      await tester.pump();
      danmaku.pending.single.complete(hasDanmakus);
      await tester.pumpAndSettle();

      expect(KazumiDialog.observer.hasKazumiDialog, isFalse);
      expect(beforeApplyCount, 1);
      expect(selected.single.toJson(), {
        'episodeId': 42003,
        'animeTitle': _anime.animeTitle,
        'episodeTitle': _episodeTitle,
      });
      expect(danmaku.enabled, [hasDanmakus]);
      expect(find.text(hasDanmakus ? '已切换弹幕源' : '暂无弹幕'), findsOneWidget);
    });
  }
}

class _TemporaryPaths extends PathProviderPlatform {
  _TemporaryPaths(this.directory);
  final String directory;

  @override
  Future<String> getApplicationSupportPath() async => directory;
}

class _Danmaku extends Fake implements PlayerDanmakuController {
  final episodeIds = <int>[];
  final guards = <DanmakuApplyGuard?>[];
  final pending = <Completer<bool?>>[];
  final enabled = <bool>[];

  @override
  Future<bool?> getDanDanmakuByEpisodeID(
    int episodeID, {
    DanmakuApplyGuard? canApply,
  }) {
    episodeIds.add(episodeID);
    guards.add(canApply);
    final response = Completer<bool?>();
    pending.add(response);
    return response.future;
  }

  @override
  void setDanmakuEnabled(bool value) => enabled.add(value);
}
