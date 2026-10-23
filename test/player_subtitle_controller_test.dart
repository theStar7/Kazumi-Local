import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/modules/local_video/local_video.dart';
import 'package:kazumi/pages/player/controller/player_subtitle_controller.dart';
import 'package:kazumi/services/player/subtitle_backend.dart';
import 'package:path/path.dart' as path;

void main() {
  late PlayerSubtitleController controller;
  late _Backend backend;
  late Directory directory;
  late File first;
  late File second;
  LocalSubtitleSettings? stored;
  late List<LocalSubtitleSettings> writes;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('kazumi_subtitle_');
    first = await File(
      path.join(directory.path, '中文 & [1].ass'),
    ).writeAsString('fixture');
    second = await File(
      path.join(directory.path, 'second.srt'),
    ).writeAsString('fixture');
    controller = PlayerSubtitleController();
    backend = _Backend();
    stored = null;
    writes = [];
  });

  tearDown(() async {
    controller.dispose();
    await backend.events.close();
    await directory.delete(recursive: true);
  });

  void bind({
    _Backend? target,
    Future<void> Function(LocalSubtitleSettings)? save,
  }) {
    controller.bind(
      target ?? backend,
      readSettings: () => stored,
      saveSettings:
          save ??
          (settings) async {
            stored = settings;
            writes.add(settings);
          },
      canApply: () => true,
    );
  }

  Future<void> ready() async {
    bind();
    backend.loaded = true;
    await controller.refresh();
  }

  test(
    'waits for real tracks and restores the latest stored choice once',
    () async {
      bind();
      await controller.refresh();
      expect(controller.ready, isFalse);
      expect(backend.selections, isEmpty);
      stored = const LocalSubtitleSettings(
        source: LocalSubtitleSource.embedded,
        embeddedTrackId: '2',
      );
      backend.loaded = true;
      await controller.refresh();
      await controller.refresh();
      expect(backend.selected, '2');
      expect(backend.selections, ['2']);
      expect(controller.tracks.map((t) => t.id), ['1', '2']);
      expect(writes, isEmpty);
    },
  );

  test(
    'embedded choice and disabled state keep the external association',
    () async {
      await ready();
      await controller.pickExternal(() async => first.path);
      expect(backend.selected, 'external-1');
      await controller.selectEmbedded('2');
      await controller.setEnabled(false);
      expect(backend.selected, 'no');
      expect(stored!.enabled, isFalse);
      expect(stored!.embeddedTrackId, '2');
      expect(stored!.externalPath, first.path);
      await controller.setEnabled(true);
      expect(backend.selected, '2');
      await controller.selectExternal();
      expect(backend.selected, 'external-1');
      expect(backend.additions, [first.path]);
    },
  );

  test(
    'replacing and removing external subtitles unloads old tracks',
    () async {
      await ready();
      await controller.pickExternal(() async => first.path);
      await controller.pickExternal(() async => second.path);
      expect(backend.removals, ['external-1']);
      expect(stored!.externalPath, second.path);
      await controller.removeExternal();
      expect(backend.removals, ['external-1', 'external-2']);
      expect(backend.selected, '1');
      expect(stored!.source, LocalSubtitleSource.auto);
      expect(stored!.externalPath, isNull);
    },
  );

  test(
    'removing an external association preserves an embedded selection',
    () async {
      await ready();
      await controller.pickExternal(() async => first.path);
      await controller.selectEmbedded('2');
      await controller.removeExternal();
      expect(backend.selected, '2');
      expect(stored!.embeddedTrackId, '2');
      expect(stored!.source, LocalSubtitleSource.embedded);
      expect(stored!.externalPath, isNull);
    },
  );

  test(
    'a successful command without an actual track never replaces the old choice',
    () async {
      await ready();
      await controller.pickExternal(() async => first.path);
      backend.rejectExternal = true;
      final previousWrites = writes.length;
      await controller.pickExternal(() async => second.path);
      expect(backend.selected, 'external-1');
      expect(stored!.externalPath, first.path);
      expect(writes, hasLength(previousWrites));
      expect(controller.message, contains('失败'));
      expect(backend.removals, isEmpty);
    },
  );

  test(
    'missing saved external subtitles fall back without deleting saved settings',
    () async {
      stored = LocalSubtitleSettings(
        source: LocalSubtitleSource.external,
        externalPath: '${directory.path}/missing.ass',
      );
      final saved = stored!.toJson();
      await ready();
      expect(backend.selected, '1');
      expect(controller.settings.source, LocalSubtitleSource.auto);
      expect(controller.message, contains('无法恢复'));
      expect(stored!.toJson(), saved);
      expect(writes, isEmpty);
    },
  );

  test('a vanished embedded track falls back to the default', () async {
    stored = const LocalSubtitleSettings(
      source: LocalSubtitleSource.embedded,
      embeddedTrackId: '99',
    );
    await ready();
    expect(backend.selected, '1');
    expect(controller.settings.source, LocalSubtitleSource.auto);
    expect(stored!.embeddedTrackId, '99');
    expect(writes, isEmpty);
  });

  test(
    'disabled saved external choice does not load or validate its file',
    () async {
      stored = const LocalSubtitleSettings(
        enabled: false,
        source: LocalSubtitleSource.external,
        externalPath: 'missing.ass',
      );
      await ready();
      expect(backend.selected, 'no');
      expect(backend.additions, isEmpty);
      expect(controller.message, isNull);
      expect(controller.settings.externalPath, 'missing.ass');
    },
  );

  test('cancelled picker leaves the choice untouched', () async {
    await ready();
    await controller.selectEmbedded('2');
    await controller.pickExternal(() async => null);
    expect(backend.selected, '2');
    expect(writes, hasLength(1));
  });

  test('late picker cannot affect a newly bound video', () async {
    await ready();
    final picker = Completer<String?>();
    final pending = controller.pickExternal(() => picker.future);
    controller.detach();
    final next = _Backend()..loaded = true;
    bind(target: next);
    await controller.refresh();
    picker.complete(first.path);
    await pending;
    expect(next.additions, isEmpty);
    expect(backend.additions, isEmpty);
    expect(writes, isEmpty);
    await next.events.close();
  });

  test('later user choice invalidates a pending file picker', () async {
    await ready();
    final picker = Completer<String?>();
    final pending = controller.pickExternal(() => picker.future);
    await controller.selectEmbedded('2');
    picker.complete(first.path);
    await pending;
    expect(backend.selected, '2');
    expect(backend.additions, isEmpty);
  });

  test(
    'save failure reports unsaved playback without undoing the selection',
    () async {
      backend.loaded = true;
      bind(save: (_) async => throw FileSystemException('storage unavailable'));
      await controller.refresh();
      await controller.selectEmbedded('2');
      expect(backend.selected, '2');
      expect(controller.settings.embeddedTrackId, '2');
      expect(controller.message, '已切换，保存失败');
    },
  );

  test('detach cancels delayed restoration on the previous backend', () async {
    bind();
    await controller.refresh();
    controller.detach();
    backend.loaded = true;
    backend.events.add(null);
    await Future<void>.delayed(Duration.zero);
    expect(backend.selections, isEmpty);
    expect(controller.ready, isFalse);
  });

  test(
    'failed default selection restores an external track even after unloading it',
    () async {
      await ready();
      await controller.pickExternal(() async => first.path);
      backend.failNextDefault = true;
      await controller.selectDefault();
      expect(controller.settings.source, LocalSubtitleSource.external);
      expect(stored!.source, LocalSubtitleSource.external);
      expect(
        backend.tracks.any(
          (track) =>
              track.id == backend.selected && track.externalPath == first.path,
        ),
        isTrue,
      );
      expect(controller.message, contains('失败'));
    },
  );

  test(
    'failed replacement does not leave an extra external track loaded',
    () async {
      await ready();
      await controller.pickExternal(() async => first.path);
      backend.addWithoutSelection = true;
      await controller.pickExternal(() async => second.path);
      expect(
        backend.tracks.where((track) => track.externalPath != null),
        hasLength(1),
      );
      expect(backend.selected, 'external-1');
      expect(stored!.externalPath, first.path);
    },
  );
}

class _Backend implements SubtitleBackend {
  final events = StreamController<void>.broadcast();
  bool loaded = false;
  bool rejectExternal = false;
  bool failNextDefault = false;
  bool addWithoutSelection = false;
  String selected = '1';
  final selections = <String>[];
  final additions = <String>[];
  final removals = <String>[];
  final tracks = <SubtitleTrackInfo>[
    const SubtitleTrackInfo(id: '1', title: '简体', language: 'zh', codec: 'ass'),
    const SubtitleTrackInfo(
      id: '2',
      title: 'English',
      language: 'en',
      codec: 'subrip',
    ),
  ];

  @override
  Stream<void> get changes => events.stream;
  @override
  Future<SubtitleSnapshot> read() async => SubtitleSnapshot(
    ready: loaded,
    tracks: loaded ? List.of(tracks) : [],
    selectedId: selected,
  );
  @override
  Future<void> select(String id) async {
    if (id == 'auto' && failNextDefault) {
      failNextDefault = false;
      throw StateError('native selection failed');
    }
    selections.add(id);
    selected = id == 'auto' ? '1' : id;
  }

  @override
  Future<void> addExternal(String path) async {
    additions.add(path);
    if (rejectExternal) return;
    final id = 'external-${additions.length}';
    tracks.add(SubtitleTrackInfo(id: id, externalPath: path));
    if (!addWithoutSelection) selected = id;
  }

  @override
  Future<void> remove(String id) async {
    removals.add(id);
    tracks.removeWhere((track) => track.id == id);
  }
}
