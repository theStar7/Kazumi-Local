// Generated-media native verification; never reads the user's media library.
// .tools/flutter/bin/flutter.bat test --no-pub scripts/verify_local_video_covers.dart --reporter expanded
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:kazumi/modules/local_video/local_video.dart';
import 'package:kazumi/services/local_video/local_video_cover_service.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as path;
import 'package:win32/win32.dart';

Set<int> _visibleWindows() {
  final windows = <int>{};
  final processId = calloc<Uint32>();
  final callback = NativeCallable<WNDENUMPROC>.isolateLocal((
    int hwnd,
    int data,
  ) {
    GetWindowThreadProcessId(hwnd, processId);
    if (processId.value == pid && IsWindowVisible(hwnd) != 0) windows.add(hwnd);
    return 1;
  }, exceptionalReturn: 0);
  try {
    EnumWindows(callback.nativeFunction, 0);
  } finally {
    callback.close();
    calloc.free(processId);
  }
  return windows;
}

void main() {
  test(
    'native covers are cached, invalidated and generated without a window',
    () async {
      expect(Platform.isWindows, isTrue);
      final output = Directory(
        path.absolute('.dart_tool/local_video_library_validation'),
      );
      final media = Directory(path.join(output.path, 'generated_media'));
      await media.create(recursive: true);
      final videoFile = File(path.join(media.path, '封面 # sample.mp4'));
      final ffmpeg =
          Platform.environment['COVER_FFMPEG'] ?? r'D:\Tool\mpv\ffmpeg.exe';
      final dll =
          Platform.environment['COVER_MPV_DLL'] ??
          path.absolute('build/windows/x64/runner/Release/libmpv-2.dll');
      expect(File(ffmpeg).existsSync(), isTrue);
      expect(File(dll).existsSync(), isTrue);
      MediaKit.ensureInitialized(libmpv: dll);
      final checks = <String>[];
      void checked(String label, bool passed) {
        expect(passed, isTrue, reason: label);
        checks.add(label);
        // ignore: avoid_print
        print('PASS: $label');
      }

      Future<void> generate(String color) async {
        final result = await Process.run(ffmpeg, [
          '-y',
          '-hide_banner',
          '-loglevel',
          'error',
          '-f',
          'lavfi',
          '-i',
          'color=c=$color:s=800x450:r=24:d=2',
          '-f',
          'lavfi',
          '-i',
          'sine=frequency=880:sample_rate=44100:duration=2',
          '-c:v',
          'libx264',
          '-preset',
          'ultrafast',
          '-pix_fmt',
          'yuv420p',
          '-c:a',
          'aac',
          '-shortest',
          videoFile.path,
        ]);
        expect(result.exitCode, 0, reason: '${result.stderr}');
      }

      final windowsBefore = _visibleWindows();
      final extraWindows = <int>{};
      final windowMonitor = Timer.periodic(const Duration(milliseconds: 20), (
        _,
      ) {
        extraWindows.addAll(_visibleWindows().difference(windowsBefore));
      });
      final covers = LocalVideoCoverService(
        cacheDirectory: () async =>
            Directory(path.join(output.path, 'native_covers')),
      );
      try {
        await generate('red');
        final video = LocalVideo(
          id: 'generated',
          path: videoFile.path,
          name: '封面 # sample.mp4',
        );
        final beforeHash = sha256
            .convert(await videoFile.readAsBytes())
            .toString();
        final concurrent = await Future.wait([
          covers.load(video),
          covers.load(video),
        ]);
        checked(
          'concurrent requests return one cached cover',
          concurrent.every(
            (file) => file != null && file.path == concurrent.first!.path,
          ),
        );
        final first = concurrent.first!;
        final red = image.decodeImage(await first.readAsBytes())!;
        checked(
          'cover dimensions are bounded and preserve 16:9',
          red.width <= 640 && (red.width / red.height - 16 / 9).abs() < .02,
        );
        checked(
          'generated red frame is rendered',
          red.getPixel(red.width ~/ 2, red.height ~/ 2).r > 180 &&
              red.getPixel(red.width ~/ 2, red.height ~/ 2).b < 70,
        );
        await first.copy(path.join(output.path, 'cover_red.jpg'));
        final coverStamp = (await first.stat()).modified;
        final hit = await covers.load(video);
        checked(
          'cache hit does not rewrite JPEG',
          hit?.path == first.path && (await hit!.stat()).modified == coverStamp,
        );
        checked(
          'cover extraction preserves original media bytes',
          sha256.convert(await videoFile.readAsBytes()).toString() ==
              beforeHash,
        );

        await covers.suspend();
        checked(
          'cached cover remains readable while suspended',
          (await covers.load(video))?.path == first.path,
        );
        await generate('blue');
        await videoFile.setLastModified(
          DateTime.now().add(const Duration(seconds: 2)),
        );
        var finished = false;
        final pending = covers.load(video).then((file) {
          finished = true;
          return file;
        });
        await Future<void>.delayed(const Duration(milliseconds: 120));
        checked('uncached work stays paused', !finished);
        covers.resume();
        final second = await pending;
        checked(
          'file modification changes cache identity',
          second != null && second.path != first.path,
        );
        final blue = image.decodeImage(await second!.readAsBytes())!;
        checked(
          'replacement blue frame is rendered',
          blue.getPixel(blue.width ~/ 2, blue.height ~/ 2).b > 180 &&
              blue.getPixel(blue.width ~/ 2, blue.height ~/ 2).r < 70,
        );
        await second.copy(path.join(output.path, 'cover_blue.jpg'));
        final brokenFile = File(path.join(media.path, 'broken.mp4'));
        await brokenFile.writeAsString('deliberately invalid generated video');
        final brokenVideo = LocalVideo(
          id: 'broken',
          path: brokenFile.path,
          name: 'broken.mp4',
        );
        var brokenFinished = false;
        final interrupted = covers.load(brokenVideo).then((file) {
          brokenFinished = true;
          return file;
        });
        await Future<void>.delayed(const Duration(milliseconds: 150));
        checked(
          'invalid native extraction is pending before suspension',
          !brokenFinished,
        );
        final cancellation = Stopwatch()..start();
        await covers.suspend();
        checked(
          'suspension releases pending native extraction promptly',
          await interrupted == null &&
              cancellation.elapsed < const Duration(seconds: 2),
        );
        covers.resume();
        checked(
          'invalid video returns placeholder result',
          await covers.load(
                LocalVideo(
                  id: 'broken',
                  path: brokenFile.path,
                  name: 'broken.mp4',
                ),
              ) ==
              null,
        );
        checked(
          'extractor creates no extra visible process window',
          extraWindows.isEmpty &&
              _visibleWindows().difference(windowsBefore).isEmpty,
        );
        await File(path.join(output.path, 'cover_report.json')).writeAsString(
          const JsonEncoder.withIndent('  ').convert({
            'scope':
                'Generated MP4 with audio; actual cover service and bundled Windows mpv; no application UI interaction.',
            'checks': checks,
            'passed': true,
            'extraVisibleWindows': extraWindows.length,
            'images': ['cover_red.jpg', 'cover_blue.jpg'],
            'audioOutput':
                'Native backend configured ao=null; separate native feasibility probe verified ao=null and vo=null properties.',
          }),
        );
      } finally {
        windowMonitor.cancel();
        await covers.dispose();
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
