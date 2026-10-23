import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/modules/local_video/local_video.dart';
import 'package:kazumi/pages/player/controller/player_subtitle_controller.dart';
import 'package:kazumi/pages/player/player_subtitle_sheet.dart';
import 'package:kazumi/services/player/subtitle_backend.dart';
import 'package:path/path.dart' as path;

void main() {
  late PlayerSubtitleController controller;
  late _Backend backend;
  late Directory temporary;
  late File first;
  late File second;
  late List<LocalSubtitleSettings> writes;
  LocalSubtitleSettings? stored;
  var allowed = true;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('kazumi_subtitle_sheet_');
    first = await File(
      path.join(temporary.path, '简体字幕.ass'),
    ).writeAsString('fixture');
    second = await File(
      path.join(temporary.path, 'English.srt'),
    ).writeAsString('fixture');
    backend = _Backend();
    controller = PlayerSubtitleController();
    writes = [];
    stored = null;
    allowed = true;
  });

  tearDown(() async {
    controller.dispose();
    await backend.events.close();
    await temporary.delete(recursive: true);
  });

  Future<void> bind({bool ready = true}) async {
    backend.ready = ready;
    controller.bind(
      backend,
      readSettings: () => stored,
      saveSettings: (value) async {
        stored = value;
        writes.add(value);
      },
      canApply: () => allowed,
    );
    await controller.refresh();
    backend.selections.clear();
  }

  Future<void> mount(
    WidgetTester tester, {
    Future<String?> Function()? pickFile,
  }) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: SizedBox(
            width: 640,
            height: 560,
            child: PlayerSubtitleSheet(
              controller: controller,
              canApply: () => allowed,
              pickFile: pickFile,
            ),
          ),
        ),
      ),
    ),
  );

  Future<void> settle(WidgetTester tester) async {
    await tester.pumpAndSettle();
  }

  Future<void> tap(WidgetTester tester, String text) async {
    await tester.ensureVisible(find.text(text));
    // Keep file I/O and its serial queue in the real async zone together.
    await tester.runAsync(() async {
      await tester.tap(find.text(text));
      await controller.refresh();
    });
    await settle(tester);
  }

  testWidgets('shows embedded title, language and codec and selects a track', (
    tester,
  ) async {
    await tester.runAsync(() => bind());
    await mount(tester);
    expect(find.text('字幕'), findsOneWidget);
    expect(find.text('简体中文'), findsOneWidget);
    expect(find.textContaining('zh'), findsOneWidget);
    expect(find.textContaining('ass'), findsOneWidget);
    await tap(tester, 'English');
    expect(controller.settings.source, LocalSubtitleSource.embedded);
    expect(controller.settings.embeddedTrackId, '2');
    expect(backend.selected, '2');
    expect(
      tester
          .widget<RadioGroup<String>>(find.byType(RadioGroup<String>))
          .groupValue,
      '2',
    );
    await tap(tester, '跟随视频默认字幕');
    expect(controller.settings.source, LocalSubtitleSource.auto);
    expect(
      tester
          .widget<RadioGroup<String>>(find.byType(RadioGroup<String>))
          .groupValue,
      'auto',
    );
  });

  testWidgets('switch retains the selected track while subtitles are hidden', (
    tester,
  ) async {
    await tester.runAsync(() => bind());
    await mount(tester);
    await tap(tester, 'English');
    await tester.runAsync(() async {
      await tester.tap(find.byType(Switch));
      await controller.refresh();
    });
    await settle(tester);
    expect(controller.settings.enabled, isFalse);
    expect(controller.settings.embeddedTrackId, '2');
    expect(backend.selected, 'no');
    await tester.runAsync(() async {
      await tester.tap(find.byType(Switch));
      await controller.refresh();
    });
    await settle(tester);
    expect(backend.selected, '2');
  });

  testWidgets('adds, replaces and removes an external association', (
    tester,
  ) async {
    await tester.runAsync(() => bind());
    final picks = [first.path, second.path];
    await mount(tester, pickFile: () async => picks.removeAt(0));
    await tap(tester, '添加外部字幕');
    expect(controller.settings.externalPath, first.path);
    expect(find.text('简体字幕.ass'), findsOneWidget);
    await tap(tester, 'English');
    expect(find.text('简体字幕.ass'), findsOneWidget);
    expect(controller.settings.source, LocalSubtitleSource.embedded);
    await tap(tester, '简体字幕.ass');
    expect(controller.settings.source, LocalSubtitleSource.external);
    await tap(tester, '替换文件');
    expect(controller.settings.externalPath, second.path);
    expect(find.text('English.srt'), findsOneWidget);
    await tap(tester, 'English');
    await tap(tester, '移除关联');
    expect(controller.settings.externalPath, isNull);
    expect(controller.settings.source, LocalSubtitleSource.embedded);
    expect(find.text('English.srt'), findsNothing);
    expect(find.text('添加外部字幕'), findsOneWidget);
  });

  testWidgets('cancelled file selection keeps the existing choice', (
    tester,
  ) async {
    await tester.runAsync(() => bind());
    await tester.runAsync(() => controller.selectEmbedded('2'));
    final before = writes.length;
    await mount(tester, pickFile: () async => null);
    await tap(tester, '添加外部字幕');
    expect(controller.settings.embeddedTrackId, '2');
    expect(controller.settings.externalPath, isNull);
    expect(writes, hasLength(before));
  });

  testWidgets('video without embedded tracks can still add an external file', (
    tester,
  ) async {
    backend.tracks.clear();
    await tester.runAsync(() => bind());
    await mount(tester, pickFile: () async => first.path);
    expect(find.text('此视频没有内嵌字幕'), findsOneWidget);
    await tap(tester, '添加外部字幕');
    expect(controller.settings.externalPath, first.path);
  });

  testWidgets('initial loading disables subtitle actions', (tester) async {
    await tester.runAsync(() => bind(ready: false));
    var picks = 0;
    await mount(
      tester,
      pickFile: () async {
        picks++;
        return first.path;
      },
    );
    expect(find.text('正在读取字幕轨道…'), findsOneWidget);
    expect(tester.widget<Switch>(find.byType(Switch)).onChanged, isNull);
    await tap(tester, '添加外部字幕');
    expect(picks, 0);
    expect(writes, isEmpty);
  });

  testWidgets('busy controller disables every subtitle action', (tester) async {
    await tester.runAsync(() => bind());
    await mount(tester, pickFile: () async => first.path);
    backend.selectionGate = Completer<void>();
    await tester.runAsync(() => tester.tap(find.text('English')));
    await tester.pump();
    expect(controller.busy, isTrue);
    expect(tester.widget<Switch>(find.byType(Switch)).onChanged, isNull);
    final addButton = tester.widget<TextButton>(
      find.widgetWithText(TextButton, '添加外部字幕'),
    );
    expect(addButton.onPressed, isNull);
    backend.selectionGate!.complete();
    await tester.runAsync(controller.refresh);
    await settle(tester);
    expect(controller.busy, isFalse);
  });

  testWidgets('shows the controller error message', (tester) async {
    await tester.runAsync(() => bind());
    await mount(tester);
    backend.rejectSelection = true;
    await tap(tester, 'English');
    expect(find.text(controller.message!), findsOneWidget);
    expect(find.textContaining('字幕切换失败'), findsOneWidget);
  });

  testWidgets('stale canApply blocks callbacks even without a rebuild', (
    tester,
  ) async {
    await tester.runAsync(() => bind());
    var picks = 0;
    await mount(
      tester,
      pickFile: () async {
        picks++;
        return first.path;
      },
    );
    allowed = false;
    await tester.tap(find.text('English'));
    await tester.tap(find.text('添加外部字幕'));
    await tester.tap(find.byType(Switch));
    await tester.pump();
    expect(picks, 0);
    expect(backend.selections, isEmpty);
    expect(writes, isEmpty);
  });

  for (final size in [const Size(1280, 720), const Size(640, 360)]) {
    testWidgets('adaptive modal scrolls without overflow at $size', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      backend.tracks.addAll(
        List.generate(
          12,
          (index) => SubtitleTrackInfo(
            id: '${index + 3}',
            title: '很长的字幕标题 ${index + 3} / subtitle track with a long title',
            language: 'zh-Hans',
            codec: 'ass',
          ),
        ),
      );
      await tester.runAsync(() => bind());
      late BuildContext page;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              page = context;
              return const Scaffold(body: Text('player'));
            },
          ),
        ),
      );
      unawaited(
        showPlayerSubtitleSheet(
          page,
          controller: controller,
          canApply: () => allowed,
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('添加外部字幕'), 200);
      expect(find.text('添加外部字幕').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();
      expect(find.text('player'), findsOneWidget);
    });
  }

  testWidgets(
    'detach closes only its current sheet and leaves the player page',
    (tester) async {
      await tester.runAsync(() => bind());
      late BuildContext page;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              page = context;
              return const Scaffold(body: Text('player'));
            },
          ),
        ),
      );
      unawaited(
        showPlayerSubtitleSheet(
          page,
          controller: controller,
          canApply: () => allowed,
        ),
      );
      await tester.pumpAndSettle();
      controller.detach();
      await tester.pumpAndSettle();
      expect(find.byType(PlayerSubtitleSheet), findsNothing);
      expect(find.text('player'), findsOneWidget);
    },
  );

  testWidgets('initial loading does not close the modal', (tester) async {
    await tester.runAsync(() => bind(ready: false));
    late BuildContext page;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            page = context;
            return const Scaffold(body: Text('player'));
          },
        ),
      ),
    );
    unawaited(
      showPlayerSubtitleSheet(
        page,
        controller: controller,
        canApply: () => allowed,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(PlayerSubtitleSheet), findsOneWidget);
    expect(find.text('正在读取字幕轨道…'), findsOneWidget);
  });

  testWidgets('detach never pops another route above the subtitle sheet', (
    tester,
  ) async {
    await tester.runAsync(() => bind());
    late BuildContext page;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            page = context;
            return const Scaffold(body: Text('player'));
          },
        ),
      ),
    );
    unawaited(
      showPlayerSubtitleSheet(
        page,
        controller: controller,
        canApply: () => allowed,
      ),
    );
    await tester.pumpAndSettle();
    unawaited(
      showDialog<void>(
        context: page,
        builder: (_) => const AlertDialog(title: Text('other dialog')),
      ),
    );
    await tester.pumpAndSettle();
    controller.detach();
    await tester.pumpAndSettle();
    expect(find.text('other dialog'), findsOneWidget);
  });
}

class _Backend implements SubtitleBackend {
  final events = StreamController<void>.broadcast();
  bool ready = false;
  bool rejectSelection = false;
  Completer<void>? selectionGate;
  String selected = '1';
  final selections = <String>[];
  final tracks = <SubtitleTrackInfo>[
    const SubtitleTrackInfo(
      id: '1',
      title: '简体中文',
      language: 'zh',
      codec: 'ass',
    ),
    const SubtitleTrackInfo(
      id: '2',
      title: 'English',
      language: 'en',
      codec: 'subrip',
    ),
  ];
  var nextExternal = 0;

  @override
  Stream<void> get changes => events.stream;
  @override
  Future<SubtitleSnapshot> read() async => SubtitleSnapshot(
    ready: ready,
    tracks: ready ? List.of(tracks) : [],
    selectedId: selected,
  );
  @override
  Future<void> select(String id) async {
    await selectionGate?.future;
    if (rejectSelection) throw StateError('selection rejected');
    selections.add(id);
    selected = id == 'auto' ? '1' : id;
  }

  @override
  Future<void> addExternal(String filePath) async {
    selected = 'external-${++nextExternal}';
    tracks.add(SubtitleTrackInfo(id: selected, externalPath: filePath));
  }

  @override
  Future<void> remove(String id) async =>
      tracks.removeWhere((track) => track.id == id);
}
