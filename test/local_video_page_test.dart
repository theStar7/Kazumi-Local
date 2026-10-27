import 'dart:async';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive_ce.dart';
import 'package:kazumi/modules/local_video/local_video.dart';
import 'package:kazumi/modules/local_video/local_video_folder.dart';
import 'package:kazumi/pages/local_video/local_video_page.dart';
import 'package:kazumi/repositories/local_video_repository.dart';
import 'package:kazumi/services/local_video/local_video_cover_service.dart';
import 'package:image/image.dart' as image;
import 'package:kazumi/services/storage/storage.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Future<void> onPlay(List<LocalVideo> videos, String id) async {}
  late Directory settingsDirectory;
  late PathProviderPlatform originalPaths;
  late Directory temporary;
  late Box<String> box;
  late LocalVideoRepository repository;
  final windowCalls = <String>[];

  setUpAll(() async {
    settingsDirectory = await Directory.systemTemp.createTemp(
      'kazumi_local_page_settings_',
    );
    originalPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _TemporaryPaths(settingsDirectory.path);
    Hive.init('${settingsDirectory.path}/hive');
    await GStorage.init();
    await GStorage.putSetting(SettingsKeys.showWindowButton, false);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('window_manager'), (
          call,
        ) async {
          windowCalls.add(call.method);
          return null;
        });
  });

  tearDownAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('window_manager'), null);
    await Hive.close();
    PathProviderPlatform.instance = originalPaths;
    await settingsDirectory.delete(recursive: true);
  });

  setUp(() async {
    windowCalls.clear();
    temporary = await Directory.systemTemp.createTemp('kazumi_local_page_');
    box = _MemoryBox();
    repository = LocalVideoRepository(box, foldersBox: _MemoryBox());
    FilePicker.platform = _Picker();
  });

  tearDown(() async {
    await temporary.delete(recursive: true);
  });

  for (final width in [360.0, 1280.0]) {
    testWidgets(
      'local page keeps a working window close button at width $width',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(width, 800);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        await pumpLibrary(
          tester,
          MaterialApp(
            home: LocalVideoPage(repository: repository, onPlay: onPlay),
          ),
        );
        await settlePage(tester);

        expect(find.byType(CloseButton), findsOneWidget);
        await tester.tap(find.byType(CloseButton));
        await tester.pump();
        expect(windowCalls, ['close']);
      },
      skip: !Platform.isWindows,
    );
  }

  testWidgets('empty library offers both import actions', (tester) async {
    await pumpLibrary(
      tester,
      MaterialApp(
        home: LocalVideoPage(repository: repository, onPlay: onPlay),
      ),
    );
    expect(find.text('本地视频'), findsOneWidget);
    expect(find.text('导入视频'), findsOneWidget);
    expect(find.text('导入文件夹'), findsOneWidget);
    expect(find.text('还没有本地视频'), findsOneWidget);
  });

  testWidgets('shows progress and binding; removing keeps original file', (
    tester,
  ) async {
    late File file;
    late LocalVideo video;
    await tester.runAsync(() async {
      file = await File('${temporary.path}/第1集.mp4').writeAsString('fixture');
      video = (await repository.importFiles([file.path])).added.single;
      await repository.saveProgress(
        video.id,
        const Duration(seconds: 30),
        const Duration(minutes: 2),
      );
      await repository.setDanmakuBinding(
        video.id,
        const LocalDanmakuBinding(
          episodeId: 123,
          animeTitle: 'Anime',
          episodeTitle: 'EP1',
        ),
      );
    });
    await pumpLibrary(
      tester,
      MaterialApp(
        home: LocalVideoPage(repository: repository, onPlay: onPlay),
      ),
    );
    expect(find.text('第1集.mp4'), findsOneWidget);
    expect(find.textContaining('00:30 / 02:00'), findsOneWidget);
    expect(find.textContaining('Anime · EP1'), findsOneWidget);
    await tester.tap(find.byTooltip('更多操作'));
    await settlePage(tester);
    await tester.tap(find.text('从列表移除'));
    await settlePage(tester);
    await tester.runAsync(() async {
      await waitUntil(() => repository.videos.isEmpty);
    });
    await settlePage(tester);
    expect(repository.videos, isEmpty);
    expect(await tester.runAsync(file.exists), isTrue);
    expect(find.text('还没有本地视频'), findsOneWidget);
  });

  testWidgets('clear binding preserves video and progress', (tester) async {
    late LocalVideo video;
    await tester.runAsync(() async {
      final file = await File(
        '${temporary.path}/2.mkv',
      ).writeAsString('fixture');
      video = (await repository.importFiles([file.path])).added.single;
      await repository.saveProgress(
        video.id,
        const Duration(seconds: 15),
        const Duration(minutes: 1),
      );
      await repository.setDanmakuBinding(
        video.id,
        const LocalDanmakuBinding(
          episodeId: 124,
          animeTitle: 'Anime',
          episodeTitle: 'EP2',
        ),
      );
    });
    await pumpLibrary(
      tester,
      MaterialApp(
        home: LocalVideoPage(repository: repository, onPlay: onPlay),
      ),
    );
    await tester.tap(find.byTooltip('更多操作'));
    await settlePage(tester);
    await tester.tap(find.text('清除弹幕关联'));
    await settlePage(tester);
    await tester.runAsync(() async {
      await waitUntil(
        () => repository.findById(video.id)!.danmakuBinding == null,
      );
    });
    await settlePage(tester);
    expect(repository.findById(video.id)!.danmakuBinding, isNull);
    expect(repository.findById(video.id)!.positionMilliseconds, 15000);
    expect(find.textContaining('未关联弹幕'), findsOneWidget);
  });
  testWidgets('cancelling either picker leaves the library empty', (
    tester,
  ) async {
    await pumpLibrary(
      tester,
      MaterialApp(
        home: LocalVideoPage(repository: repository, onPlay: onPlay),
      ),
    );
    await tester.tap(find.text('导入视频'));
    await settlePage(tester);
    await tester.tap(find.text('导入文件夹'));
    await settlePage(tester);
    expect(repository.videos, isEmpty);
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets(
    'multi selection imports files and folder import deduplicates recursively',
    (tester) async {
      late File a;
      late File b;
      await tester.runAsync(() async {
        a = await File('${temporary.path}/2.mp4').writeAsString('fixture');
        await Directory('${temporary.path}/nested').create();
        b = await File(
          '${temporary.path}/nested/10.mkv',
        ).writeAsString('fixture');
      });
      FilePicker.platform = _Picker(
        selection: FilePickerResult([
          PlatformFile(name: '2.mp4', path: a.path, size: 7),
          PlatformFile(name: '10.mkv', path: b.path, size: 7),
        ]),
        directory: temporary.path,
      );
      await pumpLibrary(
        tester,
        MaterialApp(
          home: LocalVideoPage(repository: repository, onPlay: onPlay),
        ),
      );
      await tester.tap(find.text('导入视频'));
      await settleIo(tester, () => repository.videos.length == 2);
      await settleIo(
        tester,
        () => find
            .byWidgetPredicate(
              (widget) =>
                  widget is LinearProgressIndicator && widget.value == null,
            )
            .evaluate()
            .isEmpty,
      );
      expect(find.text('2.mp4'), findsOneWidget);
      expect(find.text('10.mkv'), findsOneWidget);
      await tester.tap(find.text('导入文件夹'));
      await settleIo(
        tester,
        () => find
            .byWidgetPredicate(
              (widget) =>
                  widget is LinearProgressIndicator && widget.value == null,
            )
            .evaluate()
            .isEmpty,
      );
      expect(repository.videos, hasLength(2));
    },
  );

  testWidgets(
    'play uses naturally sorted siblings; missing records stay in library',
    (tester) async {
      late LocalVideo selected;
      late LocalVideo missing;
      await tester.runAsync(() async {
        for (final name in ['10.mp4', '2.mp4', '1.mp4']) {
          final file = await File(
            '${temporary.path}/$name',
          ).writeAsString('fixture');
          final video = (await repository.importFiles([
            file.path,
          ])).added.single;
          if (name == '2.mp4') selected = video;
          if (name == '1.mp4') missing = video;
        }
        await File(missing.path).delete();
      });
      List<LocalVideo>? played;
      String? initialId;
      await pumpLibrary(
        tester,
        MaterialApp(
          home: LocalVideoPage(
            repository: repository,
            onPlay: (videos, id) async {
              played = videos;
              initialId = id;
            },
          ),
        ),
      );
      await settleIo(
        tester,
        () => find.textContaining('文件已丢失').evaluate().isNotEmpty,
      );
      await tester.tap(find.text('2.mp4'));
      await settleIo(tester, () => played != null);
      expect(played!.map((video) => video.name), ['1.mp4', '2.mp4', '10.mp4']);
      expect(initialId, selected.id);
      await settlePage(tester);
      played = null;
      await tester.tap(find.text('1.mp4'));
      await settleIo(
        tester,
        () => find.text('文件已丢失，请恢复原路径下的文件或重新导入').evaluate().isNotEmpty,
      );
      expect(played, isNull);
      expect(repository.findById(missing.id), isNotNull);
    },
  );
  testWidgets('creates a virtual folder and enters it through a card', (
    tester,
  ) async {
    await pumpLibrary(
      tester,
      MaterialApp(
        home: LocalVideoPage(repository: repository, onPlay: onPlay),
      ),
    );
    await tester.tap(find.text('新建文件夹'));
    await settlePage(tester);
    await tester.enterText(find.byType(TextField), '收藏');
    await tester.pump();
    await tester.tap(find.text('创建'));
    await settlePage(tester);
    expect(repository.folders.single.name, '收藏');
    expect(find.text('0 个视频 · 0 个文件夹'), findsOneWidget);
    await tester.tap(find.text('收藏'));
    await settlePage(tester);
    expect(find.byTooltip('返回上级'), findsOneWidget);
    expect(find.text('添加已有视频'), findsOneWidget);
    expect(find.text('文件夹为空'), findsOneWidget);
  });

  testWidgets(
    'disk cards preserve imported hierarchy without rescanning on entry or refresh',
    (tester) async {
      late Directory disk;
      await tester.runAsync(() async {
        disk = await Directory('${temporary.path}/连续剧').create();
        await Directory('${disk.path}/花絮').create();
        await File('${disk.path}/1.mp4').writeAsString('fixture');
        await File('${disk.path}/花絮/extra.mp4').writeAsString('fixture');
        await repository.importDirectory(disk.path);
        await File('${disk.path}/2.mp4').writeAsString('fixture');
      });
      await pumpLibrary(
        tester,
        MaterialApp(
          home: LocalVideoPage(repository: repository, onPlay: onPlay),
        ),
      );
      await settlePage(tester);
      expect(find.text('连续剧'), findsOneWidget);
      expect(find.text('1.mp4'), findsNothing);
      await tester.tap(find.text('连续剧'));
      await settlePage(tester);
      expect(find.text('2.mp4'), findsNothing);
      await tester.tap(find.byTooltip('刷新'));
      await settlePage(tester);
      expect(find.text('2.mp4'), findsNothing);
      expect(find.text('花絮'), findsOneWidget);
      expect(find.text('extra.mp4'), findsNothing);
      expect(find.text('新建文件夹'), findsOneWidget);
      expect(find.text('导入视频'), findsOneWidget);
      expect(find.text('添加已有视频'), findsOneWidget);
      expect(find.byTooltip('刷新'), findsOneWidget);
      await tester.tap(find.byTooltip('返回上级'));
      await settleIo(tester, () => find.byTooltip('返回上级').evaluate().isEmpty);
      expect(find.text('连续剧'), findsOneWidget);
      expect(find.text('1.mp4'), findsNothing);
    },
  );
  testWidgets(
    'virtual folders nest, rename and delete without removing videos',
    (tester) async {
      late LocalVideo video;
      await tester.runAsync(() async {
        video = (await repository.importFiles([
          (await File(
            '${temporary.path}/shared.mp4',
          ).writeAsString('fixture')).path,
        ])).added.single;
        final parent = await repository.createVirtualFolder('收藏');
        await repository.createVirtualFolder('子分类', parentId: parent.id);
        await repository.addVideosToFolder(parent.id, [video.id]);
      });
      await pumpLibrary(
        tester,
        MaterialApp(
          home: LocalVideoPage(repository: repository, onPlay: onPlay),
        ),
      );
      await tester.tap(find.text('收藏'));
      await settlePage(tester);
      expect(find.text('子分类'), findsOneWidget);
      await tester.tap(find.byTooltip('文件夹操作'));
      await settlePage(tester);
      await tester.tap(find.text('重命名'));
      await settlePage(tester);
      await tester.enterText(find.byType(TextField), '新分类');
      await tester.pump();
      await tester.tap(find.text('保存'));
      await settlePage(tester);
      expect(find.text('新分类'), findsOneWidget);
      await tester.tap(find.text('新分类'));
      await settlePage(tester);
      expect(find.text('收藏'), findsOneWidget);
      expect(find.text('新分类'), findsOneWidget);
      await tester.tap(find.text('媒体库'));
      await settlePage(tester);
      await tester.tap(find.byTooltip('文件夹操作'));
      await settlePage(tester);
      await tester.tap(find.text('删除文件夹'));
      await settlePage(tester);
      await tester.tap(find.text('删除'));
      await settlePage(tester);
      expect(repository.folders, isEmpty);
      expect(repository.findById(video.id), isNotNull);
      expect(await tester.runAsync(() => File(video.path).exists()), isTrue);
    },
  );

  testWidgets(
    'adding existing videos creates shared references and removing only unlinks current category',
    (tester) async {
      late LocalVideo video;
      late String secondId;
      await tester.runAsync(() async {
        video = (await repository.importFiles([
          (await File(
            '${temporary.path}/shared.mp4',
          ).writeAsString('fixture')).path,
        ])).added.single;
        await repository.saveProgress(
          video.id,
          const Duration(seconds: 12),
          const Duration(minutes: 1),
        );
        await repository.createVirtualFolder('收藏');
        final second = await repository.createVirtualFolder('稍后看');
        secondId = second.id;
        await repository.addVideosToFolder(second.id, [video.id]);
      });
      await pumpLibrary(
        tester,
        MaterialApp(
          home: LocalVideoPage(repository: repository, onPlay: onPlay),
        ),
      );
      await tester.tap(find.text('收藏'));
      await settlePage(tester);
      await tester.tap(find.text('添加已有视频'));
      await settlePage(tester);
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pump();
      await tester.tap(find.text('添加'));
      await settlePage(tester);
      expect(find.text('shared.mp4'), findsOneWidget);
      expect(find.text('00:12 / 01:00'), findsOneWidget);
      await tester.tap(find.byTooltip('更多操作'));
      await settlePage(tester);
      expect(find.text('从列表移除'), findsNothing);
      await tester.tap(find.text('从文件夹移除'));
      await settlePage(tester);
      expect(find.text('shared.mp4'), findsNothing);
      expect(repository.findById(video.id)!.positionMilliseconds, 12000);
      expect(repository.videosIn(secondId).single.id, video.id);
    },
  );

  testWidgets(
    'a category playback snapshot is naturally sorted and excludes child and other categories',
    (tester) async {
      late LocalVideo selected;
      await tester.runAsync(() async {
        final folder = await repository.createVirtualFolder('播放分类');
        final child = await repository.createVirtualFolder(
          '子分类',
          parentId: folder.id,
        );
        final other = await repository.createVirtualFolder('其他分类');
        for (final name in [
          '10.mp4',
          '2.mp4',
          '1.mp4',
          'child.mp4',
          'other.mp4',
        ]) {
          final video = (await repository.importFiles([
            (await File(
              '${temporary.path}/$name',
            ).writeAsString('fixture')).path,
          ])).added.single;
          await repository.addVideosToFolder(
            name == 'child.mp4'
                ? child.id
                : name == 'other.mp4'
                ? other.id
                : folder.id,
            [video.id],
          );
          if (name == '2.mp4') selected = video;
        }
      });
      List<LocalVideo>? played;
      String? initial;
      await pumpLibrary(
        tester,
        MaterialApp(
          home: LocalVideoPage(
            repository: repository,
            onPlay: (videos, id) async {
              played = videos;
              initial = id;
            },
          ),
        ),
      );
      await tester.tap(find.text('播放分类'));
      await settlePage(tester);
      await tester.tap(find.text('2.mp4'));
      await settleIo(tester, () => played != null);
      await settlePage(tester);
      expect(played!.map((video) => video.name), ['1.mp4', '2.mp4', '10.mp4']);
      expect(initial, selected.id);
    },
  );

  testWidgets(
    'refresh retains a missing disk directory and its video records',
    (tester) async {
      late Directory disk;
      await tester.runAsync(() async {
        disk = await Directory('${temporary.path}/离线目录').create();
        await File('${disk.path}/missing.mp4').writeAsString('fixture');
        await repository.importDirectory(disk.path);
        await disk.delete(recursive: true);
      });
      await pumpLibrary(
        tester,
        MaterialApp(
          home: LocalVideoPage(repository: repository, onPlay: onPlay),
        ),
      );
      expect(find.text('目录无法访问，记录已保留'), findsNothing);
      await tester.tap(find.text('离线目录'));
      await settlePage(tester);
      expect(find.textContaining('部分目录或文件无法访问'), findsNothing);
      expect(find.text('新建文件夹'), findsOneWidget);
      expect(find.text('missing.mp4'), findsOneWidget);
      expect(find.textContaining('文件已丢失'), findsOneWidget);
      expect(repository.videos, hasLength(1));
      expect(find.byTooltip('更多操作'), findsOneWidget);
    },
  );

  for (final width in [360.0, 1280.0]) {
    testWidgets(
      'folder and video cards have 16:9 covers without overflow at $width',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(width, 800);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        await tester.runAsync(() async {
          await repository.createVirtualFolder('很长的分类文件夹名称会在卡片中正确换行');
          await repository.importFiles([
            (await File(
              '${temporary.path}/很长的视频文件名称.mp4',
            ).writeAsString('fixture')).path,
          ]);
        });
        await pumpLibrary(
          tester,
          MaterialApp(
            home: LocalVideoPage(repository: repository, onPlay: onPlay),
          ),
        );
        final grid = tester.widget<GridView>(find.byType(GridView));
        final delegate =
            grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
        expect(delegate.crossAxisCount, width == 360 ? 1 : greaterThan(1));
        expect(
          tester
              .widgetList<AspectRatio>(find.byType(AspectRatio))
              .map((widget) => widget.aspectRatio),
          everyElement(16 / 9),
        );
        expect(tester.takeException(), isNull);
        expect(find.byType(CloseButton), findsOneWidget);
      },
    );
  }

  testWidgets(
    'covers load asynchronously once and failed frames keep a placeholder',
    (tester) async {
      late LocalVideo video;
      late File cover;
      await tester.runAsync(() async {
        video = (await repository.importFiles([
          (await File(
            '${temporary.path}/cover.mp4',
          ).writeAsString('fixture')).path,
        ])).added.single;
        cover = await File(
          '${temporary.path}/cover.png',
        ).writeAsBytes(image.encodePng(image.Image(width: 32, height: 18)));
      });
      final service = _FakeCovers()..autoComplete = false;
      Widget page() => MaterialApp(
        home: LocalVideoPage(
          repository: repository,
          onPlay: onPlay,
          coverService: service,
        ),
      );
      await pumpLibrary(tester, page());
      expect(find.byIcon(Icons.video_file_outlined), findsNWidgets(2));
      expect(service.loads, [video.id]);
      await pumpLibrary(tester, page());
      expect(service.loads, [video.id]);
      service.pending[video.id]!.complete(cover);
      await settleIo(tester, () => find.byType(Image).evaluate().isNotEmpty);
      await settlePage(tester);
      expect(find.byType(Image), findsOneWidget);
      await settleIo(
        tester,
        () =>
            find.byType(RawImage).evaluate().isNotEmpty &&
            tester.widget<RawImage>(find.byType(RawImage)).image != null,
      );
      await tester.tap(find.byTooltip('刷新'));
      await settlePage(tester);
      // A retry after refresh may fail independently of the earlier frame.
      service.pending[video.id]!.complete(null);
      await settleIo(tester, () => find.byType(Image).evaluate().isEmpty);
      expect(find.byType(Image), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'cover generation suspends before playback and resumes after returning',
    (tester) async {
      await tester.runAsync(() async {
        await repository.importFiles([
          (await File(
            '${temporary.path}/play.mp4',
          ).writeAsString('fixture')).path,
        ]);
      });
      final service = _FakeCovers()..suspendGate = Completer<void>();
      final playing = Completer<void>();
      var opened = false;
      await pumpLibrary(
        tester,
        MaterialApp(
          home: LocalVideoPage(
            repository: repository,
            coverService: service,
            onPlay: (_, _) async {
              opened = true;
              service.events.add('play');
              await playing.future;
            },
          ),
        ),
      );
      await tester.tap(find.text('play.mp4'));
      await settleIo(tester, () => service.events.contains('suspend'));
      expect(opened, isFalse);
      service.suspendGate!.complete();
      await settleIo(tester, () => opened);
      expect(service.events, ['suspend', 'play']);
      playing.complete();
      await settleIo(tester, () => service.events.contains('resume'));
      await settlePage(tester);
      expect(service.events, ['suspend', 'play', 'resume']);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(service.events.last, 'dispose');
    },
  );

  testWidgets(
    'the page creates one cover service across parent rebuilds and disposes it',
    (tester) async {
      final service = _FakeCovers();
      var created = 0;
      Widget page() => MaterialApp(
        home: LocalVideoPage(
          repository: repository,
          createCoverService: () {
            created++;
            return service;
          },
          onPlay: onPlay,
        ),
      );
      await pumpLibrary(tester, page());
      await pumpLibrary(tester, page());
      expect(created, 1);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(service.events, ['dispose']);
    },
  );

  testWidgets('library initialization finishes before actions are enabled', (
    tester,
  ) async {
    final gate = Completer<void>();
    final delayed = _InitializingRepository(box, _MemoryBox(), gate);
    await tester.pumpWidget(
      MaterialApp(
        home: LocalVideoPage(repository: delayed, onPlay: onPlay),
      ),
    );
    await tester.pump();
    expect(delayed.initializationStarted, isTrue);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '导入视频'))
          .onPressed,
      isNull,
    );
    gate.complete();
    await settlePage(tester);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '导入视频'))
          .onPressed,
      isNotNull,
    );
  });
  testWidgets(
    'long press video moves into folder and sticky library zone moves it out without playback',
    (tester) async {
      late LocalVideo video;
      var plays = 0;
      await tester.runAsync(() async {
        video = (await repository.importFiles([
          (await File(
            '${temporary.path}/drag.mp4',
          ).writeAsString('fixture')).path,
        ])).added.single;
      });
      final folder = await repository.createVirtualFolder('目标');
      await pumpLibrary(
        tester,
        MaterialApp(
          home: LocalVideoPage(
            repository: repository,
            onPlay: (_, _) async {
              plays++;
            },
          ),
        ),
      );
      await dragCard(
        tester,
        find.byKey(ValueKey('video-${video.id}')),
        tester.getCenter(find.byKey(ValueKey('folder-${folder.id}'))),
      );
      await settlePage(tester);
      expect(repository.videosIn(null), isEmpty);
      expect(repository.videosIn(folder.id).single.id, video.id);
      expect(plays, 0);
      await tester.tap(find.byKey(ValueKey('folder-${folder.id}')));
      await settlePage(tester);
      final gesture = await startCardDrag(
        tester,
        find.byKey(ValueKey('video-${video.id}')),
      );
      expect(find.byKey(const ValueKey('move-library')), findsOneWidget);
      await gesture.moveTo(
        tester.getCenter(find.byKey(const ValueKey('move-library'))),
      );
      await gesture.up();
      await settlePage(tester);
      expect(repository.videosIn(folder.id), isEmpty);
      expect(repository.videosIn(null).single.id, video.id);
      expect(plays, 0);
    },
  );
  testWidgets(
    'long press folder moves into folder and back through library breadcrumb',
    (tester) async {
      final source = await repository.createVirtualFolder('源文件夹');
      final target = await repository.createVirtualFolder('目标文件夹');
      await pumpLibrary(
        tester,
        MaterialApp(
          home: LocalVideoPage(repository: repository, onPlay: onPlay),
        ),
      );
      await dragCard(
        tester,
        find.byKey(ValueKey('folder-${source.id}')),
        tester.getCenter(find.byKey(ValueKey('folder-${target.id}'))),
      );
      await settlePage(tester);
      expect(repository.findFolderById(source.id)!.parentId, target.id);
      await tester.tap(find.byKey(ValueKey('folder-${target.id}')));
      await settlePage(tester);
      await dragCard(
        tester,
        find.byKey(ValueKey('folder-${source.id}')),
        tester.getCenter(find.byKey(const ValueKey('breadcrumb-root'))),
      );
      await settlePage(tester);
      expect(repository.findFolderById(source.id)!.parentId, isNull);
    },
  );
  testWidgets('cancel and invalid folder destinations preserve hierarchy', (
    tester,
  ) async {
    final parent = await repository.createVirtualFolder('父文件夹');
    final child = await repository.createVirtualFolder(
      '子文件夹',
      parentId: parent.id,
    );
    await pumpLibrary(
      tester,
      MaterialApp(
        home: LocalVideoPage(repository: repository, onPlay: onPlay),
      ),
    );
    final source = find.byKey(ValueKey('folder-${parent.id}'));
    final gesture = await startCardDrag(tester, source);
    await gesture.moveTo(tester.getCenter(source));
    await gesture.up();
    await settlePage(tester);
    final cancelled = await startCardDrag(tester, source);
    await cancelled.moveBy(const Offset(20, 0));
    await cancelled.cancel();
    await settlePage(tester);
    expect(repository.findFolderById(parent.id)!.parentId, isNull);
    await tester.tap(
      find.descendant(of: source, matching: find.byTooltip('文件夹操作')),
    );
    await settlePage(tester);
    await tester.tap(find.text('移动到文件夹…'));
    await settlePage(tester);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '移动到此处'))
          .onPressed,
      isNull,
    );
    expect(find.byKey(ValueKey('move-choice-${parent.id}')), findsNothing);
    expect(find.byKey(ValueKey('move-choice-${child.id}')), findsNothing);
    await tester.tap(find.text('取消'));
    await settlePage(tester);
    expect(repository.findFolderById(parent.id)!.parentId, isNull);
    expect(repository.findFolderById(child.id)!.parentId, parent.id);
  });
  testWidgets('imported folder menu is at bottom right and supports move', (
    tester,
  ) async {
    late LocalVideoFolder disk;
    await tester.runAsync(() async {
      final directory = await Directory('${temporary.path}/来源').create();
      await repository.importDirectory(directory.path);
      disk = repository.folders.single;
    });
    final target = await repository.createVirtualFolder('收藏');
    await pumpLibrary(
      tester,
      MaterialApp(
        home: LocalVideoPage(repository: repository, onPlay: onPlay),
      ),
    );
    final card = find.byKey(ValueKey('folder-${disk.id}'));
    final menu = find.descendant(of: card, matching: find.byTooltip('文件夹操作'));
    expect(menu, findsOneWidget);
    final bounds = tester.getRect(card);
    final menuBounds = tester.getRect(menu);
    expect(bounds.right - menuBounds.right, lessThanOrEqualTo(8));
    expect(bounds.bottom - menuBounds.bottom, lessThanOrEqualTo(8));
    await tester.tap(menu);
    await settlePage(tester);
    expect(find.text('重命名'), findsOneWidget);
    expect(find.text('删除文件夹'), findsOneWidget);
    await tester.tap(find.text('移动到文件夹…'));
    await settlePage(tester);
    await tester.tap(find.byKey(ValueKey('move-choice-${target.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('移动到此处'));
    await settlePage(tester);
    expect(repository.findFolderById(disk.id)!.parentId, target.id);
  });

  testWidgets(
    'video chooser browses nested folders and distinguishes root from cancellation',
    (tester) async {
      late LocalVideo video;
      await tester.runAsync(() async {
        video = (await repository.importFiles([
          (await File(
            '${temporary.path}/menu.mp4',
          ).writeAsString('fixture')).path,
        ])).added.single;
      });
      final parent = await repository.createVirtualFolder('分类');
      final child = await repository.createVirtualFolder(
        '嵌套',
        parentId: parent.id,
      );
      await pumpLibrary(
        tester,
        MaterialApp(
          home: LocalVideoPage(repository: repository, onPlay: onPlay),
        ),
      );
      Future<void> openChooser() async {
        await tester.tap(find.byTooltip('更多操作'));
        await settlePage(tester);
        await tester.tap(find.text('移动到文件夹…'));
        await settlePage(tester);
      }

      await openChooser();
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '移动到此处'))
            .onPressed,
        isNull,
      );
      await tester.tap(find.byKey(ValueKey('move-choice-${parent.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('move-choice-${child.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await settlePage(tester);
      expect(repository.videosIn(null).single.id, video.id);
      await openChooser();
      await tester.tap(find.byKey(ValueKey('move-choice-${parent.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('move-choice-${child.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('移动到此处'));
      await settlePage(tester);
      expect(repository.videosIn(child.id).single.id, video.id);
      await tester.tap(find.byKey(ValueKey('folder-${parent.id}')));
      await settlePage(tester);
      await tester.tap(find.byKey(ValueKey('folder-${child.id}')));
      await settlePage(tester);
      await openChooser();
      await tester.tap(find.byKey(const ValueKey('move-choice-root')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('移动到此处'));
      await settlePage(tester);
      expect(repository.videosIn(child.id), isEmpty);
      expect(repository.videosIn(null).single.id, video.id);
    },
  );
  testWidgets(
    'video menu stays bottom right and cancelled long press does not play',
    (tester) async {
      late LocalVideo video;
      var plays = 0;
      await tester.runAsync(() async {
        video = (await repository.importFiles([
          (await File(
            '${temporary.path}/cancel.mp4',
          ).writeAsString('fixture')).path,
        ])).added.single;
      });
      await pumpLibrary(
        tester,
        MaterialApp(
          home: LocalVideoPage(
            repository: repository,
            onPlay: (_, _) async {
              plays++;
            },
          ),
        ),
      );
      final card = find.byKey(ValueKey('video-${video.id}'));
      final menu = find.descendant(of: card, matching: find.byTooltip('更多操作'));
      expect(
        tester.getRect(card).bottom - tester.getRect(menu).bottom,
        lessThanOrEqualTo(8),
      );
      final gesture = await startCardDrag(tester, card);
      await gesture.moveBy(const Offset(30, 10));
      await gesture.cancel();
      await settlePage(tester);
      expect(repository.videosIn(null).single.id, video.id);
      expect(plays, 0);
    },
  );
  testWidgets(
    'drag edge scroll stops on cancel and sticky target stays visible',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(360, 800);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      for (var i = 0; i < 24; i++) {
        await repository.createVirtualFolder(
          '文件夹${i.toString().padLeft(2, '0')}',
        );
      }
      await pumpLibrary(
        tester,
        MaterialApp(
          home: LocalVideoPage(repository: repository, onPlay: onPlay),
        ),
      );
      final scrollable = tester.state<ScrollableState>(
        find.descendant(
          of: find.byType(GridView),
          matching: find.byType(Scrollable),
        ),
      );
      final first = repository.foldersIn(null).first;
      final gesture = await startCardDrag(
        tester,
        find.byKey(ValueKey('folder-${first.id}')),
      );
      final gridBounds = tester.getRect(find.byType(GridView));
      await gesture.moveTo(Offset(gridBounds.center.dx, gridBounds.bottom - 8));
      await tester.pump(const Duration(milliseconds: 300));
      expect(scrollable.position.pixels, greaterThan(0));
      expect(find.byKey(const ValueKey('move-library')), findsOneWidget);
      await gesture.cancel();
      await tester.pump();
      final stopped = scrollable.position.pixels;
      await tester.pump(const Duration(milliseconds: 300));
      expect(scrollable.position.pixels, stopped);
      expect(find.byKey(const ValueKey('move-library')), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'missing video can move to parent and current breadcrumb rejects a drop',
    (tester) async {
      final parent = await repository.createVirtualFolder('上层');
      final child = await repository.createVirtualFolder(
        '内层',
        parentId: parent.id,
      );
      late LocalVideo video;
      await tester.runAsync(() async {
        final file = await File(
          '${temporary.path}/offline.mp4',
        ).writeAsString('fixture');
        video = (await repository.importFiles([
          file.path,
        ], folderId: child.id)).added.single;
        await file.delete();
      });
      var plays = 0;
      await pumpLibrary(
        tester,
        MaterialApp(
          home: LocalVideoPage(
            repository: repository,
            onPlay: (_, _) async {
              plays++;
            },
          ),
        ),
      );
      await tester.tap(find.byKey(ValueKey('folder-${parent.id}')));
      await settlePage(tester);
      await tester.tap(find.byKey(ValueKey('folder-${child.id}')));
      await settlePage(tester);
      await dragCard(
        tester,
        find.byKey(ValueKey('video-${video.id}')),
        tester.getCenter(find.byKey(ValueKey('breadcrumb-${child.id}'))),
      );
      await settlePage(tester);
      expect(repository.videosIn(child.id).single.id, video.id);
      final gesture = await startCardDrag(
        tester,
        find.byKey(ValueKey('video-${video.id}')),
      );
      await gesture.moveTo(
        tester.getCenter(find.byKey(const ValueKey('move-parent'))),
      );
      await gesture.up();
      await settlePage(tester);
      expect(repository.videosIn(child.id), isEmpty);
      expect(repository.videosIn(parent.id).single.id, video.id);
      expect(repository.findById(video.id)!.path, video.path);
      expect(plays, 0);
    },
  );

  testWidgets('only one card drag can be active at a time', (tester) async {
    final first = await repository.createVirtualFolder('第一');
    final second = await repository.createVirtualFolder('第二');
    await pumpLibrary(
      tester,
      MaterialApp(
        home: LocalVideoPage(repository: repository, onPlay: onPlay),
      ),
    );
    final firstGesture = await startCardDrag(
      tester,
      find.byKey(ValueKey('folder-${first.id}')),
    );
    final secondGesture = await tester.startGesture(
      tester.getCenter(find.byKey(ValueKey('folder-${second.id}'))),
      pointer: 2,
    );
    await tester.pump(const Duration(milliseconds: 550));
    expect(
      find.byWidgetPredicate(
        (widget) => widget is Opacity && widget.opacity == 0.35,
      ),
      findsOneWidget,
    );
    await secondGesture.cancel();
    await firstGesture.cancel();
    await settlePage(tester);
    expect(repository.foldersIn(null), hasLength(2));
    expect(find.byKey(const ValueKey('move-library')), findsNothing);
  });

  for (final width in [360.0, 1280.0]) {
    testWidgets('move chooser has no overflow at width $width', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 800);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final folder = await repository.createVirtualFolder(
        '很长的文件夹名称用于检查层级导航和移动弹窗',
      );
      await repository.createVirtualFolder('另一个很长的文件夹名称用于检查布局');
      await pumpLibrary(
        tester,
        MaterialApp(
          home: LocalVideoPage(repository: repository, onPlay: onPlay),
        ),
      );
      final card = find.byKey(ValueKey('folder-${folder.id}'));
      final menu = find.descendant(of: card, matching: find.byTooltip('文件夹操作'));
      await tester.ensureVisible(menu);
      await tester.pumpAndSettle();
      await tester.tap(menu);
      await settlePage(tester);
      await tester.tap(find.text('移动到文件夹…'));
      await settlePage(tester);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('取消'));
      await settlePage(tester);
      expect(find.byType(CloseButton), findsOneWidget);
    });
  }

  testWidgets(
    'refresh retries failed library initialization before enabling actions',
    (tester) async {
      final retrying = _FailOnceInitializingRepository(
        box,
        foldersBox: _MemoryBox(),
      );
      await pumpLibrary(
        tester,
        MaterialApp(
          home: LocalVideoPage(repository: retrying, onPlay: onPlay),
        ),
      );
      expect(find.textContaining('媒体库初始化失败'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '导入视频'))
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.refresh))
            .onPressed,
        isNotNull,
      );
      await tester.tap(find.byTooltip('刷新'));
      await settlePage(tester);
      expect(retrying.attempts, 2);
      expect(find.textContaining('媒体库初始化失败'), findsNothing);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '导入视频'))
            .onPressed,
        isNotNull,
      );
    },
  );

  testWidgets(
    'drag keeps tracking after source card scrolls out of the grid cache',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(360, 800);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      for (var i = 0; i < 24; i++) {
        await repository.createVirtualFolder(
          '长列表${i.toString().padLeft(2, '0')}',
        );
      }
      await pumpLibrary(
        tester,
        MaterialApp(
          home: LocalVideoPage(repository: repository, onPlay: onPlay),
        ),
      );
      final first = repository.foldersIn(null).first;
      final card = find.byKey(ValueKey('folder-${first.id}'));
      final gesture = await startCardDrag(tester, card);
      final grid = tester.getRect(find.byType(GridView));
      final scrollable = tester.state<ScrollableState>(
        find.descendant(
          of: find.byType(GridView),
          matching: find.byType(Scrollable),
        ),
      );
      await gesture.moveTo(Offset(grid.center.dx, grid.bottom - 8));
      await tester.pump(const Duration(seconds: 2));
      expect(card, findsNothing);
      final down = scrollable.position.pixels;
      await gesture.moveTo(Offset(grid.center.dx, grid.top + 8));
      await tester.pump(const Duration(milliseconds: 200));
      expect(scrollable.position.pixels, lessThan(down));
      await gesture.cancel();
      await tester.pump();
      final stopped = scrollable.position.pixels;
      await tester.pump(const Duration(milliseconds: 300));
      expect(scrollable.position.pixels, stopped);
      expect(find.byKey(const ValueKey('move-library')), findsNothing);
    },
  );

  testWidgets('disposing the page during a drag stops edge scrolling', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 800);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    for (var i = 0; i < 8; i++) {
      await repository.createVirtualFolder('离开${i.toString().padLeft(2, '0')}');
    }
    await pumpLibrary(
      tester,
      MaterialApp(
        home: LocalVideoPage(repository: repository, onPlay: onPlay),
      ),
    );
    final first = repository.foldersIn(null).first;
    final gesture = await startCardDrag(
      tester,
      find.byKey(ValueKey('folder-${first.id}')),
    );
    final grid = tester.getRect(find.byType(GridView));
    await gesture.moveTo(Offset(grid.center.dx, grid.bottom - 8));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpWidget(const SizedBox());
    await gesture.cancel();
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'same-frame pointer downs create only one drag and stop its scrolling',
    (tester) async {
      final first = await repository.createVirtualFolder('01');
      final second = await repository.createVirtualFolder('02');
      for (var i = 3; i < 24; i++) {
        await repository.createVirtualFolder(i.toString().padLeft(2, '0'));
      }
      await pumpLibrary(
        tester,
        MaterialApp(
          home: LocalVideoPage(repository: repository, onPlay: onPlay),
        ),
      );
      final firstGesture = await tester.startGesture(
        tester.getCenter(find.byKey(ValueKey('folder-${first.id}'))),
        pointer: 1,
      );
      final secondGesture = await tester.startGesture(
        tester.getCenter(find.byKey(ValueKey('folder-${second.id}'))),
        pointer: 2,
      );
      await tester.pump(const Duration(milliseconds: 550));
      expect(
        find.byWidgetPredicate(
          (widget) => widget is Opacity && widget.opacity == 0.35,
        ),
        findsOneWidget,
      );
      final grid = tester.getRect(find.byType(GridView));
      final scrollable = tester.state<ScrollableState>(
        find.descendant(
          of: find.byType(GridView),
          matching: find.byType(Scrollable),
        ),
      );
      await firstGesture.moveTo(Offset(grid.center.dx, grid.bottom - 8));
      await tester.pump(const Duration(milliseconds: 200));
      expect(scrollable.position.pixels, greaterThan(0));
      await secondGesture.cancel();
      await tester.pump();
      expect(find.byKey(const ValueKey('move-library')), findsOneWidget);
      await firstGesture.cancel();
      await tester.pump();
      final stopped = scrollable.position.pixels;
      await tester.pump(const Duration(milliseconds: 300));
      expect(scrollable.position.pixels, stopped);
      expect(find.byKey(const ValueKey('move-library')), findsNothing);
      expect(repository.foldersIn(null), hasLength(23));
    },
  );

  for (final frames in [40, 160]) {
    testWidgets(
      'stationary edge drop uses current folder after $frames scroll frames',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(360, 800);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        final parent = await repository.createVirtualFolder('容器');
        for (var i = 0; i < 30; i++) {
          await repository.createVirtualFolder(
            i.toString().padLeft(2, '0'),
            parentId: parent.id,
          );
        }
        final children = repository.foldersIn(parent.id);
        final source = children.first;
        await pumpLibrary(
          tester,
          MaterialApp(
            home: LocalVideoPage(repository: repository, onPlay: onPlay),
          ),
        );
        await tester.tap(find.byKey(ValueKey('folder-${parent.id}')));
        await settlePage(tester);
        final gesture = await startCardDrag(
          tester,
          find.byKey(ValueKey('folder-${source.id}')),
        );
        final grid = tester.getRect(find.byType(GridView));
        // The gap between the two sticky zones leaves the grid reachable.
        final pointer = Offset(grid.center.dx, grid.bottom - 24);
        LocalVideoFolder folderAtPointer() => children.firstWhere((folder) {
          final card = find.byKey(ValueKey('folder-${folder.id}'));
          return card.evaluate().isNotEmpty &&
              tester.getRect(card).contains(pointer);
        });
        await gesture.moveTo(pointer);
        await tester.pump();
        final previous = folderAtPointer();
        for (var i = 0; i < frames; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        final current = folderAtPointer();
        expect(current.id, isNot(previous.id));
        expect(
          find.byKey(ValueKey('folder-${previous.id}')),
          frames == 40 ? findsOneWidget : findsNothing,
        );
        await gesture.up();
        await settlePage(tester);
        expect(repository.findFolderById(source.id)!.parentId, current.id);
        expect(
          repository.findFolderById(source.id)!.parentId,
          isNot(previous.id),
        );
      },
    );
  }

  testWidgets(
    'rejected second pointer cannot drive the active drag edge scrolling',
    (tester) async {
      final first = await repository.createVirtualFolder('01');
      final second = await repository.createVirtualFolder('02');
      for (var i = 3; i < 24; i++) {
        await repository.createVirtualFolder(i.toString().padLeft(2, '0'));
      }
      await pumpLibrary(
        tester,
        MaterialApp(
          home: LocalVideoPage(repository: repository, onPlay: onPlay),
        ),
      );
      final firstGesture = await startCardDrag(
        tester,
        find.byKey(ValueKey('folder-${first.id}')),
      );
      final secondGesture = await tester.startGesture(
        tester.getCenter(find.byKey(ValueKey('folder-${second.id}'))),
        pointer: 2,
      );
      await tester.pump(const Duration(milliseconds: 550));
      final grid = tester.getRect(find.byType(GridView));
      final scrollable = tester.state<ScrollableState>(
        find.descendant(
          of: find.byType(GridView),
          matching: find.byType(Scrollable),
        ),
      );
      final before = scrollable.position.pixels;
      await secondGesture.moveTo(Offset(grid.center.dx, grid.bottom - 8));
      await tester.pump(const Duration(milliseconds: 200));
      expect(scrollable.position.pixels, before);
      await secondGesture.cancel();
      await tester.pump(const Duration(milliseconds: 200));
      expect(scrollable.position.pixels, before);
      await firstGesture.cancel();
      await settlePage(tester);
      expect(repository.foldersIn(null), hasLength(23));
    },
  );
}

class _TemporaryPaths extends PathProviderPlatform {
  _TemporaryPaths(this.directory);
  final String directory;

  @override
  Future<String> getApplicationSupportPath() async => directory;
}

Future<void> waitUntil(bool Function() done) async {
  final limit = DateTime.now().add(const Duration(seconds: 5));
  while (!done()) {
    if (DateTime.now().isAfter(limit)) {
      fail('Timed out waiting for filesystem work');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  await Future<void>.delayed(const Duration(milliseconds: 10));
}

// Disk persistence is covered by local_video_repository_test. Widget tests use
// an immediate box so Hive file locks do not depend on Flutter's fake clock.
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

  @override
  Future<void> deleteAll(Iterable<dynamic> keys) async {
    for (final key in keys) {
      _values.remove(key);
    }
  }
}

Future<void> settleIo(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 500; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
    if (done()) return;
  }
  fail('Timed out waiting for filesystem work and widget updates');
}

class _Picker extends FilePicker {
  _Picker({this.selection, this.directory});
  final FilePickerResult? selection;
  final String? directory;
  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = false,
    int compressionQuality = 0,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async => selection;
  @override
  Future<String?> getDirectoryPath({
    String? dialogTitle,
    bool lockParentWindow = false,
    String? initialDirectory,
  }) async => directory;
}

Future<void> pumpLibrary(WidgetTester tester, Widget widget) async {
  await tester.pumpWidget(widget);
  await settlePage(tester);
}

Future<void> settlePage(WidgetTester tester) async {
  await settleIo(
    tester,
    () => find
        .byWidgetPredicate(
          (widget) => widget is LinearProgressIndicator && widget.value == null,
        )
        .evaluate()
        .isEmpty,
  );
  await tester.pumpAndSettle();
}

class _FakeCovers extends Fake implements LocalVideoCoverService {
  bool autoComplete = true;
  final loads = <String>[];
  final pending = <String, Completer<File?>>{};
  final events = <String>[];
  Completer<void>? suspendGate;

  @override
  Future<File?> load(LocalVideo video) {
    loads.add(video.id);
    if (autoComplete) return Future.value(null);
    final result = pending[video.id] = Completer<File?>();
    return result.future;
  }

  @override
  Future<void> suspend() async {
    events.add('suspend');
    await suspendGate?.future;
  }

  @override
  void resume() => events.add('resume');

  @override
  Future<void> dispose() async => events.add('dispose');
}

Future<TestGesture> startCardDrag(WidgetTester tester, Finder card) async {
  final gesture = await tester.startGesture(tester.getCenter(card));
  await tester.pump(const Duration(milliseconds: 550));
  return gesture;
}

Future<void> dragCard(WidgetTester tester, Finder card, Offset target) async {
  final gesture = await startCardDrag(tester, card);
  await gesture.moveTo(target);
  await tester.pump();
  await gesture.up();
}

class _InitializingRepository extends LocalVideoRepository {
  _InitializingRepository(super.box, Box<String> folders, this.gate)
    : super(foldersBox: folders);
  final Completer<void> gate;
  bool initializationStarted = false;
  @override
  Future<void> initializeLibraryLayout() async {
    initializationStarted = true;
    await gate.future;
    await super.initializeLibraryLayout();
  }
}

class _FailOnceInitializingRepository extends LocalVideoRepository {
  _FailOnceInitializingRepository(super.box, {super.foldersBox});
  int attempts = 0;
  @override
  Future<void> initializeLibraryLayout() async {
    attempts++;
    if (attempts == 1) throw StateError('temporary persistence failure');
    await super.initializeLibraryLayout();
  }
}
