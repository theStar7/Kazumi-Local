import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/modules/local_video/local_video.dart';
import 'package:kazumi/services/local_video/local_video_cover_service.dart';
import 'package:path/path.dart' as path;

void main() {
  late Directory temporary;
  late Directory cache;
  late _FrameExtractor extractor;
  late LocalVideoCoverService service;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('kazumi_covers_');
    cache = Directory(path.join(temporary.path, 'cache'));
    extractor = _FrameExtractor();
    service = LocalVideoCoverService(
      cacheDirectory: () async => cache,
      frameExtractor: extractor,
    );
  });

  tearDown(() async {
    await service.dispose();
    await temporary.delete(recursive: true);
  });

  Future<LocalVideo> video(String name) async {
    final source = await File(
      path.join(temporary.path, name),
    ).writeAsBytes([1, 2, 3]);
    return LocalVideo(id: name, path: source.path, name: name);
  }

  test('writes a cached cover without changing the source', () async {
    final item = await video('动画 & [01].mkv');
    final source = File(item.path);
    final before = await source.stat();

    final cover = await service.load(item);

    expect(cover, isNotNull);
    expect(path.isWithin(cache.path, cover!.path), isTrue);
    expect(path.extension(cover.path), '.jpg');
    expect(await cover.readAsBytes(), _FrameExtractor.jpeg);
    expect(await source.readAsBytes(), [1, 2, 3]);
    expect((await source.stat()).modified, before.modified);
  });

  test('reuses normalized path cache across service instances', () async {
    final item = await video('episode.mp4');
    final first = await service.load(item);
    final variant = item.copyWith(
      path: path.join(temporary.path, 'unused', '..', item.name),
    );
    final cached = await service.load(variant);
    await service.dispose();
    final nextExtractor = _FrameExtractor();
    service = LocalVideoCoverService(
      cacheDirectory: () async => cache,
      frameExtractor: nextExtractor,
    );

    final restored = await service.load(item);

    expect(cached?.path, first?.path);
    expect(restored?.path, first?.path);
    expect(extractor.calls, hasLength(1));
    expect(nextExtractor.calls, isEmpty);
  });

  test(
    'invalidates cache separately for modified time and size changes',
    () async {
      final item = await video('episode.mp4');
      final source = File(item.path);
      final first = await service.load(item);
      final modified = (await source.stat()).modified.add(
        const Duration(seconds: 2),
      );
      await source.setLastModified(modified);
      final second = await service.load(item);
      await source.writeAsBytes([4, 5, 6, 7]);
      await source.setLastModified(modified);
      final third = await service.load(item);

      expect(first, isNotNull);
      expect(second?.path, isNot(first?.path));
      expect(third?.path, isNot(second?.path));
      expect(extractor.calls, hasLength(3));
    },
  );

  test(
    'singleflights duplicate requests and extracts distinct files serially',
    () async {
      extractor.automatic = false;
      final firstItem = await video('first.mp4');
      final secondItem = await video('second.mp4');
      final first = service.load(firstItem);
      await _until(() => extractor.calls.length == 1);
      final duplicate = service.load(firstItem);
      final second = service.load(secondItem);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(extractor.calls, hasLength(1));
      extractor.complete();
      final firstCover = await first;
      expect((await duplicate)?.path, firstCover?.path);
      await _until(() => extractor.calls.length == 2);
      extractor.complete();

      expect(await second, isNotNull);
      expect(extractor.maximumActive, 1);
    },
  );

  test(
    'missing and non-file sources return the placeholder without extraction',
    () async {
      expect(
        await service.load(
          LocalVideo(
            id: 'missing',
            path: path.join(temporary.path, 'missing.mp4'),
            name: 'missing',
          ),
        ),
        isNull,
      );
      expect(
        await service.load(
          LocalVideo(id: 'directory', path: temporary.path, name: 'directory'),
        ),
        isNull,
      );
      expect(extractor.calls, isEmpty);
    },
  );

  test(
    'failed or unreadable media releases the worker and permits another capture',
    () async {
      extractor.failure = const FileSystemException('unreadable video');
      final failed = await service.load(await video('bad.mp4'));
      extractor.failure = null;
      final next = await service.load(await video('next.mp4'));

      expect(failed, isNull);
      expect(next, isNotNull);
      expect(extractor.cancellations, 2);
      expect(
        await cache
            .list()
            .where((entry) => entry.path.endsWith('.part'))
            .toList(),
        isEmpty,
      );
    },
  );

  test(
    'cache directory failure returns a placeholder and can be retried',
    () async {
      final item = await video('episode.mp4');
      await service.dispose();
      var fail = true;
      service = LocalVideoCoverService(
        cacheDirectory: () async {
          if (fail) throw const FileSystemException('cache unavailable');
          return cache;
        },
        frameExtractor: extractor = _FrameExtractor(),
      );
      expect(await service.load(item), isNull);
      fail = false;
      expect(await service.load(item), isNotNull);
    },
  );

  test(
    'suspend while idle stops new work and resume accepts new requests',
    () async {
      final item = await video('episode.mp4');
      await service.suspend();
      var completed = false;
      final pending = service.load(item).then((result) {
        completed = true;
        return result;
      });
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(completed, isFalse);
      expect(extractor.calls, isEmpty);
      service.resume();
      expect(await pending, isNotNull);
    },
  );

  test('a cached cover remains available while suspended', () async {
    final item = await video('episode.mp4');
    final cached = await service.load(item);
    await service.suspend();
    expect((await service.load(item))?.path, cached?.path);
    expect(extractor.calls, hasLength(1));
  });

  test(
    'suspend cancels active work, retains the queue and awaits native release',
    () async {
      extractor.automatic = false;
      final firstItem = await video('first.mp4');
      final secondItem = await video('second.mp4');
      final first = service.load(firstItem);
      await _until(() => extractor.calls.length == 1);
      final second = service.load(secondItem);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      extractor.releaseGate = Completer<void>();
      var suspended = false;
      final suspension = service.suspend().then((_) => suspended = true);
      expect(await first, isNull);
      var queuedCompleted = false;
      second.then((_) => queuedCompleted = true);
      await Future<void>.delayed(Duration.zero);
      expect(queuedCompleted, isFalse);
      expect(suspended, isFalse);
      extractor.releaseGate!.complete();
      await suspension;
      expect(extractor.active, 0);
      expect(extractor.calls, hasLength(1));
      service.resume();
      await _until(() => extractor.calls.length == 2);
      extractor.complete();
      expect(await second, isNotNull);
    },
  );

  test(
    'dispose settles requests still awaiting cache directory lookup',
    () async {
      await service.dispose();
      final entered = Completer<void>();
      final directory = Completer<Directory>();
      service = LocalVideoCoverService(
        cacheDirectory: () {
          entered.complete();
          return directory.future;
        },
        frameExtractor: extractor = _FrameExtractor(),
      );
      final pending = service.load(await video('episode.mp4'));
      await entered.future;
      await service.dispose();
      expect(await pending, isNull);
      directory.complete(cache);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(extractor.calls, isEmpty);
    },
  );

  test('discard a frame when its source changes during extraction', () async {
    extractor.automatic = false;
    final item = await video('episode.mp4');
    final pending = service.load(item);
    await _until(() => extractor.calls.isNotEmpty);
    await File(item.path).writeAsBytes([9, 8, 7, 6]);
    extractor.complete();
    expect(await pending, isNull);
    expect(await cache.exists() ? await cache.list().toList() : [], isEmpty);
  });

  test('a timeout cancels the worker before the next queued capture', () async {
    extractor.automatic = false;
    final first = service.load(await video('stuck.mp4'));
    await _until(() => extractor.calls.isNotEmpty);
    final second = service.load(await video('next.mp4'));
    expect(await first, isNull);
    await _until(() => extractor.calls.length == 2);
    extractor.complete();
    expect(await second, isNotNull);
    expect(extractor.cancellations, 2);
    expect(extractor.maximumActive, 1);
  }, timeout: const Timeout(Duration(seconds: 20)));

  test(
    'dispose resolves pending work and permanently releases the extractor',
    () async {
      extractor.automatic = false;
      final item = await video('episode.mp4');
      final active = service.load(item);
      await _until(() => extractor.calls.isNotEmpty);
      final queued = service.load(await video('second.mp4'));
      await service.dispose();
      expect(await active, isNull);
      expect(await queued, isNull);
      expect(extractor.active, 0);
      expect(extractor.disposals, 1);
      service.resume();
      expect(await service.load(item), isNull);
      await service.dispose();
      expect(extractor.disposals, 1);
    },
  );
}

Future<void> _until(bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Expected operation did not start');
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

class _FrameExtractor implements LocalVideoFrameExtractor {
  static final jpeg = Uint8List.fromList([0xff, 0xd8, 0xff, 0xd9]);
  final calls = <File>[];
  bool automatic = true;
  Object? failure;
  int active = 0;
  int maximumActive = 0;
  int cancellations = 0;
  int disposals = 0;
  Completer<void>? releaseGate;
  Completer<Uint8List?>? _capture;

  @override
  Future<Uint8List?> capture(File source) async {
    calls.add(source);
    active++;
    if (active > maximumActive) maximumActive = active;
    final capture = _capture = Completer<Uint8List?>();
    try {
      if (failure != null) throw failure!;
      if (automatic) capture.complete(jpeg);
      return await capture.future;
    } finally {
      active--;
    }
  }

  void complete() => _capture!.complete(jpeg);

  @override
  Future<void> cancel() async {
    cancellations++;
    await releaseGate?.future;
    if (_capture != null && !_capture!.isCompleted) _capture!.complete(null);
  }

  @override
  Future<void> dispose() async {
    disposals++;
    if (_capture != null && !_capture!.isCompleted) _capture!.complete(null);
  }
}
