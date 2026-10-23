import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/modules/danmaku/danmaku_module.dart';
import 'package:kazumi/utils/episode_danmaku_loader.dart';

void main() {
  test('empty result is successful and failures can be retried', () async {
    var fail = true;
    final loader = EpisodeDanmakuLoader((id) async {
      if (fail) throw StateError('offline');
      return [];
    });
    await expectLater(loader.load(1), throwsStateError);
    expect(loader.isLoading, isFalse);
    fail = false;
    expect(await loader.load(2), isEmpty);
  });

  test('latest request wins even when old request returns last', () async {
    final old = Completer<List<DanmakuEntry>>();
    final latest = Completer<List<DanmakuEntry>>();
    final loader = EpisodeDanmakuLoader(
      (id) => id == 1 ? old.future : latest.future,
    );
    final a = loader.load(1);
    final b = loader.load(2);
    latest.complete([]);
    expect(await b, isEmpty);
    old.complete([]);
    expect(await a, isNull);
    expect(loader.isLoading, isFalse);
  });

  test('switch, clear and exit invalidate pending requests', () async {
    for (final close in [false, true]) {
      final response = Completer<List<DanmakuEntry>>();
      final loader = EpisodeDanmakuLoader((id) => response.future);
      final pending = loader.load(1);
      if (close) {
        loader.close();
      } else {
        loader.cancel();
      }
      response.complete([]);
      expect(await pending, isNull);
      expect(loader.isLoading, isFalse);
    }
  });

  test('playback guard rejects A to B to A stale manual choice', () async {
    final response = Completer<List<DanmakuEntry>>();
    final loader = EpisodeDanmakuLoader((id) => response.future);
    var generation = 1;
    final captured = generation;
    final pending = loader.load(1, canApply: () => generation == captured);
    generation = 3;
    response.complete([]);
    expect(await pending, isNull);
  });

  test('cancelled failed request does not affect newer request', () async {
    final old = Completer<List<DanmakuEntry>>();
    final latest = Completer<List<DanmakuEntry>>();
    final loader = EpisodeDanmakuLoader(
      (id) => id == 1 ? old.future : latest.future,
    );
    final a = loader.load(1);
    final b = loader.load(2);
    old.completeError(StateError('late failure'));
    expect(await a, isNull);
    expect(loader.isLoading, isTrue);
    latest.complete([]);
    expect(await b, isEmpty);
  });
}
