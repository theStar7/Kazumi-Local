// Windows native integration validation using generated media only.
// Run from the project root:
// .tools/flutter/bin/flutter.bat test --no-pub scripts/verify_subtitles.dart --reporter expanded
// Optional environment variables: SUBTITLE_FFMPEG, SUBTITLE_MPV_DLL.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:kazumi/modules/local_video/local_video.dart';
import 'package:kazumi/pages/player/controller/player_subtitle_controller.dart';
import 'package:kazumi/services/player/subtitle_backend.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as path;

void main() {
  test(
    'generated subtitles render and persist through the Windows native backend',
    () async {
      final output = Directory(path.absolute('.dart_tool/subtitle_validation'));
      await output.create(recursive: true);
      final checks = <String>[];
      final report = <String, Object?>{
        'startedUtc': DateTime.now().toUtc().toIso8601String(),
        'scope':
            'Generated media; actual controller, media_kit and Windows libmpv. '
            'Native GPU screenshots, not Flutter UI interaction.',
        'checks': checks,
      };
      void checked(String label, bool success) {
        expect(success, isTrue, reason: label);
        checks.add(label);
        // ignore: avoid_print
        print('PASS: $label');
      }

      final ffmpeg =
          Platform.environment['SUBTITLE_FFMPEG'] ?? r'D:\Tool\mpv\ffmpeg.exe';
      final dll =
          Platform.environment['SUBTITLE_MPV_DLL'] ??
          path.absolute('build/windows/x64/runner/Release/libmpv-2.dll');
      Player? player;
      PlayerSubtitleController? controller;
      final nativeErrors = <String>[];
      LocalSubtitleSettings? saved;
      try {
        expect(Platform.isWindows, isTrue);
        expect(
          File(ffmpeg).existsSync(),
          isTrue,
          reason: 'Set SUBTITLE_FFMPEG to an existing ffmpeg executable.',
        );
        expect(
          File(dll).existsSync(),
          isTrue,
          reason: 'Build Windows or set SUBTITLE_MPV_DLL.',
        );
        report['ffmpeg'] = ffmpeg;
        report['libmpv'] = dll;
        await _fixtures(output, ffmpeg);
        MediaKit.ensureInitialized(libmpv: dll);

        Future<(Player, PlayerSubtitleController)> create() async {
          final current = Player(
            configuration: const PlayerConfiguration(
              vo: 'gpu',
              libass: true,
              muted: true,
              title: 'Kazumi generated subtitle validation',
            ),
          );
          current.stream.error.listen(nativeErrors.add);
          final native = current.platform as NativePlayer;
          await native.setProperty('vid', 'auto');
          await native.setProperty('ao', 'null');
          await native.setProperty('force-window', 'yes');
          await native.setProperty('sub-auto', 'no');
          await native.setProperty('sub-ass-override', 'no');
          final backend = NativeSubtitleBackend(current);
          final control = PlayerSubtitleController();
          control.bind(
            backend,
            readSettings: () => saved,
            saveSettings: (value) async {
              // Exercise the same JSON representation as per-video persistence,
              // while keeping all state out of the application's user store.
              await File(
                path.join(output.path, 'saved_settings.json'),
              ).writeAsString(jsonEncode(value.toJson()));
              saved = LocalSubtitleSettings.fromJson(
                jsonDecode(
                      await File(
                        path.join(output.path, 'saved_settings.json'),
                      ).readAsString(),
                    )
                    as Map<String, dynamic>,
              );
            },
            canApply: () => true,
          );
          await control.refresh();
          expect(
            control.ready,
            isFalse,
            reason: 'Bound before media is opened',
          );
          await current.open(
            Media(path.join(output.path, 'generated.mkv')),
            play: false,
          );
          await _until(() async => (await backend.read()).tracks.length == 2);
          await control.refresh();
          await _until(() async => control.ready && !control.busy);
          await current.seek(const Duration(seconds: 2));
          await _until(
            () async =>
                (double.tryParse(await native.getProperty('time-pos')) ?? -1) >=
                1.9,
          );
          return (current, control);
        }

        (player, controller) = await create();
        final backend = NativeSubtitleBackend(player);
        final native = player.platform as NativePlayer;
        report['mpvVersion'] = await native.getProperty('mpv-version');
        report['videoOutput'] = await native.getProperty('current-vo');
        report['initialTracks'] = await native.getProperty('track-list');
        checked(
          'native GPU output active',
          (await native.getProperty('current-vo')) == 'gpu',
        );
        checked('libass enabled', await native.getProperty('sub-ass') == 'yes');
        checked(
          'two embedded tracks discovered',
          controller.tracks.length == 2,
        );
        final ass = controller.tracks.firstWhere(
          (track) => track.codec == 'ass',
        );
        final english = controller.tracks.firstWhere(
          (track) => track.id != ass.id,
        );
        checked(
          'embedded language and title metadata retained',
          ass.language == 'chi' &&
              ass.title == 'Chinese styled ASS' &&
              english.language == 'eng',
        );

        await controller.setEnabled(false);
        checked(
          'disabled selects native sid=no',
          (await backend.read()).selectedId == 'no',
        );
        final baseline = await _capture(player, output, '01_disabled.png');

        await controller.selectEmbedded(ass.id);
        checked(
          'embedded ASS selected natively',
          (await backend.read()).selectedId == ass.id &&
              controller.message == null,
        );
        final assImage = await _capture(player, output, '02_embedded_ass.png');
        checked(
          'ASS renders visible pixels',
          _different(baseline, assImage) > 500,
        );

        await controller.selectEmbedded(english.id);
        checked(
          'embedded English selected natively',
          (await backend.read()).selectedId == english.id &&
              controller.message == null,
        );
        final englishImage = await _capture(
          player,
          output,
          '03_embedded_english.png',
        );
        checked(
          'embedded SRT renders and differs from ASS',
          _different(baseline, englishImage) > 500 &&
              _different(assImage, englishImage) > 500,
        );

        for (final extension in ['srt', 'ass', 'ssa', 'vtt']) {
          final file = path.join(output.path, '外挂 # sample.$extension');
          await controller.pickExternal(() async => file);
          final snapshot = await backend.read();
          final external = snapshot.tracks.where(
            (track) => track.externalPath != null,
          );
          checked(
            '$extension external loaded and actually selected',
            controller.message == null &&
                external.length == 1 &&
                external.single.id == snapshot.selectedId &&
                subtitlePathIdentity(external.single.externalPath!) ==
                    subtitlePathIdentity(file),
          );
          checked(
            '$extension preference saved after native success',
            saved?.source == LocalSubtitleSource.external &&
                subtitlePathIdentity(saved!.externalPath!) ==
                    subtitlePathIdentity(file),
          );
          final screenshot = await _capture(
            player,
            output,
            '04_external_$extension.png',
          );
          checked(
            '$extension has visible rendered subtitles',
            _different(baseline, screenshot) > 250,
          );
        }

        final goodSettings = saved!.toJson();
        final goodSnapshot = await backend.read();
        await controller.pickExternal(
          () async => path.join(output.path, 'malformed.srt'),
        );
        final failedSnapshot = await backend.read();
        checked(
          'malformed file rejected by actual native track-list',
          controller.message != null &&
              failedSnapshot.tracks.length == goodSnapshot.tracks.length &&
              failedSnapshot.selectedId == goodSnapshot.selectedId &&
              !failedSnapshot.tracks.any(
                (track) =>
                    track.externalPath?.endsWith('malformed.srt') == true,
              ),
        );
        checked(
          'failed external load preserves saved preference',
          jsonEncode(saved!.toJson()) == jsonEncode(goodSettings),
        );

        await controller.setEnabled(false);
        checked(
          'external can be disabled without forgetting file',
          (await backend.read()).selectedId == 'no' &&
              saved!.externalPath!.endsWith('.vtt'),
        );
        await controller.setEnabled(true);
        checked(
          'external re-enable restores actual track',
          (await backend.read()).selectedId == goodSnapshot.selectedId,
        );

        await player.seek(const Duration(seconds: 5));
        checked(
          'seek keeps external selection',
          (await backend.read()).selectedId == goodSnapshot.selectedId,
        );
        await player.setRate(1.5);
        await player.play();
        final start = double.parse(await native.getProperty('time-pos'));
        await Future<void>.delayed(const Duration(milliseconds: 600));
        await player.pause();
        final end = double.parse(await native.getProperty('time-pos'));
        checked(
          'native playback, pause and 1.5x speed work with subtitles',
          end > start + 0.3 &&
              await native.getProperty('pause') == 'yes' &&
              double.parse(await native.getProperty('speed')) == 1.5 &&
              (await backend.read()).selectedId == goodSnapshot.selectedId,
        );

        controller.dispose();
        controller = null;
        await player.dispose();
        player = null;
        (player, controller) = await create();
        var restored = await NativeSubtitleBackend(player).read();
        checked(
          'recreated player restores persisted external file and selection',
          controller.message == null &&
              restored.tracks.any(
                (track) =>
                    track.externalPath?.endsWith('.vtt') == true &&
                    track.id == restored.selectedId,
              ),
        );
        await _capture(player, output, '05_restored_external.png');

        await controller.selectEmbedded(ass.id);
        controller.dispose();
        controller = null;
        await player.dispose();
        player = null;
        (player, controller) = await create();
        restored = await NativeSubtitleBackend(player).read();
        checked(
          'recreated player restores embedded selection',
          restored.selectedId == ass.id && controller.message == null,
        );

        await controller.setEnabled(false);
        controller.dispose();
        controller = null;
        await player.dispose();
        player = null;
        (player, controller) = await create();
        checked(
          'recreated player restores disabled state',
          (await NativeSubtitleBackend(player).read()).selectedId == 'no' &&
              !controller.settings.enabled,
        );
        await controller.setEnabled(true);
        await controller.removeExternal();
        checked(
          'remove external clears per-video path',
          saved!.externalPath == null,
        );
        await controller.selectDefault();
        final autoSnapshot = await NativeSubtitleBackend(player).read();
        final autoNative = player.platform as NativePlayer;
        report['autoSelection'] = {
          'sid': await autoNative.getProperty('sid'),
          'options/sid': await autoNative.getProperty('options/sid'),
          'track-list': await autoNative.getProperty('track-list'),
        };
        checked(
          'default selection accepted',
          controller.settings.source == LocalSubtitleSource.auto &&
              controller.message == null &&
              (autoSnapshot.selectedId == 'no' ||
                  autoSnapshot.tracks.any(
                    (track) =>
                        track.id == autoSnapshot.selectedId &&
                        track.externalPath == null,
                  )),
        );
        report['status'] = 'passed';
      } catch (error, stack) {
        report['status'] = 'failed';
        report['error'] = error.toString();
        report['stack'] = stack.toString();
        rethrow;
      } finally {
        controller?.dispose();
        await player?.dispose();
        report['nativeErrors'] = nativeErrors;
        report['finishedUtc'] = DateTime.now().toUtc().toIso8601String();
        await File(
          path.join(output.path, 'report.json'),
        ).writeAsString(const JsonEncoder.withIndent('  ').convert(report));
      }
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}

Future<void> _until(Future<bool> Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 15));
  while (!await condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Native readiness');
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

Future<image.Image> _capture(
  Player player,
  Directory output,
  String name,
) async {
  // mpv redraws paused subtitle changes on its render thread.
  await Future<void>.delayed(const Duration(milliseconds: 350));
  final bytes = await player.screenshot(
    format: 'image/png',
    includeLibassSubtitles: true,
  );
  expect(bytes, isNotNull, reason: 'Native screenshot $name');
  await File(path.join(output.path, name)).writeAsBytes(bytes!);
  final decoded = image.decodePng(bytes)!;
  expect(decoded.width, 640);
  expect(decoded.height, 360);
  return decoded;
}

int _different(image.Image left, image.Image right) {
  var count = 0;
  for (var y = 0; y < left.height; y++) {
    for (var x = 0; x < left.width; x++) {
      final a = left.getPixel(x, y);
      final b = right.getPixel(x, y);
      if ((a.r - b.r).abs() + (a.g - b.g).abs() + (a.b - b.b).abs() > 45) {
        count++;
      }
    }
  }
  return count;
}

Future<void> _fixtures(Directory output, String ffmpeg) async {
  const srt = '1\n00:00:00,000 --> 00:00:11,000\nEnglish external subtitle\n';
  const ass = r'''[Script Info]
ScriptType: v4.00+
PlayResX: 640
PlayResY: 360
[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Styled,Microsoft YaHei,36,&H0000FFFF,&H000000FF,&H00400040,&H80000000,-1,0,0,0,100,100,0,0,1,3,2,8,20,20,35,1
[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:00.00,0:00:11.00,Styled,,0,0,0,,{\pos(320,65)}中文特效字幕
Dialogue: 0,0:00:00.00,0:00:11.00,Styled,,0,0,0,,{\pos(320,125)\c&H00FF80&\fs24}ASS color / outline / position
''';
  const ssa = r'''[Script Info]
ScriptType: v4.00
PlayResX: 640
PlayResY: 360
[V4 Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, TertiaryColour, BackColour, Bold, Italic, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, AlphaLevel, Encoding
Style: Default,Microsoft YaHei,30,16711935,255,0,0,-1,0,1,2,1,2,20,20,35,0,1
[Events]
Format: Marked, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: Marked=0,0:00:00.00,0:00:11.00,Default,,0,0,0,,SSA 紫色字幕
''';
  final files = <String, String>{
    'embedded.ass': ass,
    'embedded.srt': srt.replaceAll('external', 'embedded'),
    '外挂 # sample.srt': srt,
    '外挂 # sample.ass': ass,
    '外挂 # sample.ssa': ssa,
    '外挂 # sample.vtt': 'WEBVTT\n\n00:00.000 --> 00:11.000\nVTT 中文外挂字幕\n',
    'malformed.srt': 'This is deliberately malformed and contains no cues.\n',
  };
  for (final entry in files.entries) {
    await File(path.join(output.path, entry.key)).writeAsString(entry.value);
  }
  final process = await Process.run(ffmpeg, [
    '-y',
    '-hide_banner',
    '-loglevel',
    'error',
    '-f',
    'lavfi',
    '-i',
    'color=c=0x142238:s=640x360:r=24:d=12',
    '-i',
    path.join(output.path, 'embedded.ass'),
    '-i',
    path.join(output.path, 'embedded.srt'),
    '-map',
    '0:v',
    '-map',
    '1:0',
    '-map',
    '2:0',
    '-c:v',
    'libx264',
    '-preset',
    'ultrafast',
    '-crf',
    '28',
    '-c:s',
    'copy',
    '-metadata:s:s:0',
    'language=chi',
    '-metadata:s:s:0',
    'title=Chinese styled ASS',
    '-metadata:s:s:1',
    'language=eng',
    '-metadata:s:s:1',
    'title=English SRT',
    '-disposition:s:0',
    'default',
    '-disposition:s:1',
    '0',
    path.join(output.path, 'generated.mkv'),
  ]);
  expect(process.exitCode, 0, reason: 'Generate fixture: ${process.stderr}');
}
