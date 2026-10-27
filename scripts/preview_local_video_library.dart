import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:kazumi/modules/local_video/local_video.dart';
import 'package:kazumi/pages/local_video/local_video_page.dart';
import 'package:kazumi/repositories/local_video_repository.dart';
import 'package:kazumi/services/local_video/local_video_cover_service.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/utils/constants.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

// Widget-rendered screenshots with generated fixtures, never user settings or
// media. Run after verify_local_video_covers.dart generated the two JPEGs.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final output = Directory('.dart_tool/local_video_move_validation');
  final covers = Directory('.dart_tool/local_video_library_validation');
  late Directory settings;
  late PathProviderPlatform originalPaths;
  setUpAll(() async {
    await output.create(recursive: true);
    settings = await Directory.systemTemp.createTemp('kazumi_library_preview_');
    originalPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(settings.path);
    Hive.init(p.join(settings.path, 'hive'));
    await GStorage.init();
    await GStorage.putSetting(SettingsKeys.showWindowButton, false);
    final font = FontLoader(customAppFontFamily)
      ..addFont(rootBundle.load('assets/fonts/MiSans-Regular.ttf'));
    await font.load();
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
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
    await settings.delete(recursive: true);
  });

  for (final width in [360.0, 1280.0]) {
    testWidgets('render root, category and disk at $width', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 900);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      late LocalVideoRepository repository;
      await tester.runAsync(() async {
        repository = LocalVideoRepository(
          _MemoryBox(),
          foldersBox: _MemoryBox(),
        );
        final media = await settings.createTemp('media_');
        final disk = Directory(p.join(media.path, '动画课程'));
        await Directory(p.join(disk.path, '参考素材')).create(recursive: true);
        for (final name in ['1 基础.mp4', '2 光照.mp4', '10 合成.mp4']) {
          await File(p.join(disk.path, name)).writeAsBytes([0, 1]);
        }
        await repository.importDirectory(disk.path);
        final category = await repository.createVirtualFolder('继续观看');
        await repository.createVirtualFolder('收藏片段', parentId: category.id);
        for (var i = 1; i <= 5; i++) {
          final file = await File(
            p.join(media.path, '本地视频 $i.mp4'),
          ).writeAsBytes([0, 1]);
          final video = (await repository.importFiles([
            file.path,
          ])).added.single;
          await repository.saveProgress(
            video.id,
            Duration(seconds: i * 21),
            const Duration(minutes: 8),
          );
          if (i <= 3) {
            await repository.addVideosToFolder(category.id, [video.id]);
          }
          if (i == 2) {
            await repository.setDanmakuBinding(
              video.id,
              const LocalDanmakuBinding(
                episodeId: 1,
                animeTitle: '示例动画',
                episodeTitle: '第 2 集',
              ),
            );
          }
          if (i == 5) await file.delete();
        }
      });
      final boundary = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: ThemeData(
              colorSchemeSeed: Colors.indigo,
              fontFamily: customAppFontFamily,
            ),
            home: LocalVideoPage(
              repository: repository,
              coverService: _Covers(covers.absolute.path),
              onPlay: (_, _) async {},
            ),
          ),
        ),
      );
      await _settle(tester);
      await _save(
        tester,
        boundary,
        p.join(output.path, 'library_${width.toInt()}_root.png'),
      );
      await tester.tap(find.byTooltip('文件夹操作').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('移动到文件夹…'));
      await tester.pumpAndSettle();
      await _save(
        tester,
        boundary,
        p.join(output.path, 'library_${width.toInt()}_move_dialog.png'),
      );
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      final source = find.byKey(
        ValueKey('folder-${repository.foldersIn(null).first.id}'),
      );
      final drag = await tester.startGesture(tester.getCenter(source));
      await tester.pump(const Duration(milliseconds: 550));
      await drag.moveBy(const Offset(18, 10));
      await tester.pump();
      await _save(
        tester,
        boundary,
        p.join(output.path, 'library_${width.toInt()}_drag.png'),
      );
      await drag.cancel();
      await tester.pumpAndSettle();
      await tester.tap(find.text('继续观看').first);
      await _settle(tester);
      await _save(
        tester,
        boundary,
        p.join(output.path, 'library_${width.toInt()}_category.png'),
      );
      await tester.tap(find.text('媒体库'));
      await _settle(tester);
      await tester.tap(find.text('动画课程').first);
      await _settle(tester);
      await _save(
        tester,
        boundary,
        p.join(output.path, 'library_${width.toInt()}_disk.png'),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}

Future<void> _settle(WidgetTester tester) async {
  var idleFrames = 0;
  for (var i = 0; i < 500; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 50));
    final busy = find.byWidgetPredicate(
      (widget) => widget is LinearProgressIndicator && widget.value == null,
    );
    idleFrames = busy.evaluate().isEmpty ? idleFrames + 1 : 0;
    if (idleFrames == 10) return;
  }
  fail('The library did not finish its current-layer refresh');
}

Future<void> _save(WidgetTester tester, GlobalKey key, String path) async {
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    await File(path).writeAsBytes(data!.buffer.asUint8List());
    image.dispose();
  });
}

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String> getApplicationSupportPath() async => path;
}

class _Covers extends Fake implements LocalVideoCoverService {
  _Covers(this.directory);
  final String directory;
  @override
  Future<File?> load(LocalVideo video) async => video.name.contains('5')
      ? null
      : File(
          p.join(
            directory,
            video.name.contains('2') ? 'cover_blue.jpg' : 'cover_red.jpg',
          ),
        );
  @override
  Future<void> dispose() async {}
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
