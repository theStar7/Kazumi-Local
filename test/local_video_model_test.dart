import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/modules/local_video/local_video.dart';

void main() {
  test('legacy videos have no subtitle settings', () {
    final video = LocalVideo.fromJson({
      'id': 'old',
      'path': 'old.mkv',
      'name': 'old.mkv',
    });
    expect(video.subtitleSettings, isNull);
  });

  test('subtitle choice survives JSON and unrelated metadata changes', () {
    const settings = LocalSubtitleSettings(
      enabled: false,
      source: LocalSubtitleSource.embedded,
      embeddedTrackId: '2',
      externalPath: r'C:\字幕\中文 & English.ass',
    );
    const video = LocalVideo(
      id: 'id',
      path: 'video.mkv',
      name: 'video.mkv',
      subtitleSettings: settings,
    );
    final restored = LocalVideo.fromJson(
      jsonDecode(jsonEncode(video.toJson())),
    );
    expect(restored.subtitleSettings!.toJson(), settings.toJson());
    expect(
      restored.copyWith(positionMilliseconds: 99).subtitleSettings!.toJson(),
      settings.toJson(),
    );
    expect(
      restored.copyWith(clearSubtitleSettings: true).subtitleSettings,
      isNull,
    );
  });

  test('subtitle settings default to enabled automatic selection', () {
    const settings = LocalSubtitleSettings();

    expect(settings.enabled, isTrue);
    expect(settings.source, LocalSubtitleSource.auto);
    expect(settings.embeddedTrackId, isNull);
    expect(settings.externalPath, isNull);
    expect(LocalSubtitleSettings.fromJson({}).toJson(), settings.toJson());
    expect(settings.toJson()['source'], 'auto');
  });

  test('subtitle copyWith preserves choices and explicitly clears a path', () {
    const original = LocalSubtitleSettings(
      source: LocalSubtitleSource.external,
      embeddedTrackId: '2',
      externalPath: r'C:\字幕\episode 1.ass',
    );

    final disabled = original.copyWith(enabled: false);
    final embedded = disabled.copyWith(
      source: LocalSubtitleSource.embedded,
      embeddedTrackId: '3',
      clearExternalPath: true,
    );
    final replacement = original.copyWith(externalPath: 'replacement.srt');

    expect(original.enabled, isTrue);
    expect(disabled.source, LocalSubtitleSource.external);
    expect(disabled.embeddedTrackId, '2');
    expect(disabled.externalPath, original.externalPath);
    expect(embedded.enabled, isFalse);
    expect(embedded.source, LocalSubtitleSource.embedded);
    expect(embedded.embeddedTrackId, '3');
    expect(embedded.externalPath, isNull);
    expect(replacement.externalPath, 'replacement.srt');
    expect(original.externalPath, r'C:\字幕\episode 1.ass');
  });

  const binding = LocalDanmakuBinding(
    episodeId: 42,
    animeTitle: '测试番剧',
    episodeTitle: '第 2 集',
  );

  test('round trips local video metadata and its danmaku binding', () {
    const video = LocalVideo(
      id: 'video-id',
      path: r'C:\动画 & movies\第 2 集 [1080p].mkv',
      name: '第 2 集 [1080p].mkv',
      positionMilliseconds: 12345,
      durationMilliseconds: 1440000,
      danmakuBinding: binding,
    );

    final restored = LocalVideo.fromJson(
      jsonDecode(jsonEncode(video.toJson())),
    );

    expect(restored.toJson(), video.toJson());
    expect(restored.danmakuBinding!.episodeId, 42);
    expect(restored.danmakuBinding!.animeTitle, '测试番剧');
    expect(restored.danmakuBinding!.episodeTitle, '第 2 集');
  });

  test('defaults an imported video to no progress and no binding', () {
    const video = LocalVideo(id: 'id', path: 'video.mp4', name: 'video.mp4');

    expect(video.positionMilliseconds, 0);
    expect(video.durationMilliseconds, 0);
    expect(video.danmakuBinding, isNull);
    expect(LocalVideo.fromJson(video.toJson()).danmakuBinding, isNull);
  });

  test('copyWith preserves the original and explicitly clears a binding', () {
    const video = LocalVideo(
      id: 'id',
      path: 'video.mp4',
      name: 'video.mp4',
      danmakuBinding: binding,
    );

    final updated = video.copyWith(
      name: 'renamed.mp4',
      positionMilliseconds: 3000,
      durationMilliseconds: 9000,
    );
    final cleared = updated.copyWith(clearDanmakuBinding: true);

    expect(video.name, 'video.mp4');
    expect(video.positionMilliseconds, 0);
    expect(updated.id, video.id);
    expect(updated.path, video.path);
    expect(updated.name, 'renamed.mp4');
    expect(updated.positionMilliseconds, 3000);
    expect(updated.durationMilliseconds, 9000);
    expect(updated.danmakuBinding, binding);
    expect(cleared.danmakuBinding, isNull);
    expect(updated.danmakuBinding, binding);
  });

  test('round trips an independent danmaku binding', () {
    expect(
      LocalDanmakuBinding.fromJson(binding.toJson()).toJson(),
      binding.toJson(),
    );
  });
}
