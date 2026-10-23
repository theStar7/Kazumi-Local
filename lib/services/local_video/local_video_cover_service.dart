import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as image;
import 'package:kazumi/modules/local_video/local_video.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

/// Owns the native resources for one frame at a time. Captures return JPEG bytes
/// with their original aspect ratio and neither dimension greater than 640.
abstract interface class LocalVideoFrameExtractor {
  Future<Uint8List?> capture(File source);

  /// Terminates and releases the current capture, including a stalled capture.
  Future<void> cancel();
  Future<void> dispose();
}

class LocalVideoCoverService {
  LocalVideoCoverService({
    Future<Directory> Function()? cacheDirectory,
    LocalVideoFrameExtractor? frameExtractor,
  }) : _cacheDirectory = cacheDirectory ?? _defaultCacheDirectory,
       _frameExtractor = frameExtractor ?? _MpvFrameExtractor();

  final Future<Directory> Function() _cacheDirectory;
  final LocalVideoFrameExtractor _frameExtractor;
  final _requests = <Completer<File?>>{};
  final _jobs = <String, _CoverJob>{};
  final _queue = <_CoverJob>[];
  _CoverJob? _active;
  Future<void>? _worker;
  Future<void>? _disposeFuture;
  bool _draining = false;
  bool _suspended = false;
  bool _disposed = false;

  Future<File?> load(LocalVideo video) {
    if (_disposed) return Future.value(null);
    final request = Completer<File?>();
    _requests.add(request);
    unawaited(_prepare(video, request));
    return request.future;
  }

  Future<void> _prepare(LocalVideo video, Completer<File?> request) async {
    try {
      final source = File(path.normalize(File(video.path).absolute.path));
      final stat = await source.stat();
      if (request.isCompleted) return;
      if (stat.type != FileSystemEntityType.file || stat.size == 0) {
        _complete(request, null);
        return;
      }
      final normalized = Platform.isWindows
          ? source.path.toLowerCase()
          : source.path;
      final key = sha256
          .convert(
            utf8.encode(
              '$normalized|${stat.size}|${stat.modified.microsecondsSinceEpoch}',
            ),
          )
          .toString();
      final directory = await _cacheDirectory();
      if (request.isCompleted) return;
      await directory.create(recursive: true);
      if (request.isCompleted) return;
      final cached = File(path.join(directory.path, '$key.jpg'));
      if (await _hasCover(cached)) {
        _complete(request, cached);
        return;
      }
      if (request.isCompleted) return;
      final existing = _jobs[key];
      if (existing != null) {
        existing.requests.add(request);
        return;
      }
      final job = _CoverJob(key, source, stat, cached, request);
      _jobs[key] = job;
      _queue.add(job);
      _startWorker();
    } catch (_) {
      _complete(request, null);
    }
  }

  void _startWorker() {
    if (_draining || _suspended || _disposed) return;
    _worker = _drain();
  }

  Future<void> _drain() async {
    _draining = true;
    try {
      while (!_suspended && !_disposed && _queue.isNotEmpty) {
        final job = _active = _queue.removeAt(0);
        await _capture(job);
        _active = null;
        job.finished.complete();
      }
    } finally {
      _draining = false;
    }
  }

  Future<void> _capture(_CoverJob job) async {
    File? result;
    var started = false;
    final partial = File('${job.cached.path}.part');
    try {
      if (await _hasCover(job.cached)) {
        if (!job.interrupted.isCompleted) result = job.cached;
        return;
      }
      final current = await job.source.stat();
      if (job.interrupted.isCompleted || !_matches(job, current)) {
        return;
      }
      started = true;
      final bytes = await Future.any<Uint8List?>([
        Future<Uint8List?>.sync(
          () => _frameExtractor.capture(job.source),
        ).timeout(const Duration(seconds: 10)),
        job.interrupted.future,
      ]);
      if (bytes == null || bytes.isEmpty || job.interrupted.isCompleted) return;
      if (!_matches(job, await job.source.stat())) return;
      await partial.writeAsBytes(bytes, flush: true);
      if (job.interrupted.isCompleted) return;
      result = await partial.rename(job.cached.path);
    } catch (_) {
      // Unreadable media, decoding failures and unavailable caches use the card
      // placeholder. A failed capture must not block subsequent queued files.
    } finally {
      if (started) await _release(job);
      try {
        if (await partial.exists()) await partial.delete();
      } catch (_) {}
      _finish(job, job.interrupted.isCompleted ? null : result);
    }
  }

  bool _matches(_CoverJob job, FileStat stat) =>
      stat.type == FileSystemEntityType.file &&
      stat.size == job.stat.size &&
      stat.modified == job.stat.modified;

  Future<void> _release(_CoverJob job) => job.release ??= Future<void>.sync(
    _frameExtractor.cancel,
  ).catchError((Object _) {});

  void _complete(Completer<File?> request, File? result) {
    _requests.remove(request);
    if (!request.isCompleted) request.complete(result);
  }

  void _finish(_CoverJob job, File? result) {
    if (identical(_jobs[job.key], job)) _jobs.remove(job.key);
    for (final request in job.requests) {
      _complete(request, result);
    }
  }

  /// Cancels the active frame and retains queued misses until [resume]. Cached
  /// files remain available while playback owns the main player.
  Future<void> suspend() async {
    if (_disposed) return;
    _suspended = true;
    final active = _active;
    if (active == null) return;
    if (!active.interrupted.isCompleted) active.interrupted.complete(null);
    _finish(active, null);
    await _release(active);
    await active.finished.future;
  }

  void resume() {
    if (_disposed) return;
    _suspended = false;
    _startWorker();
  }

  Future<void> dispose() => _disposeFuture ??= _dispose();

  Future<void> _dispose() async {
    _disposed = true;
    _suspended = true;
    for (final request in _requests.toList()) {
      _complete(request, null);
    }
    _queue.clear();
    _jobs.clear();
    final active = _active;
    if (active != null) {
      if (!active.interrupted.isCompleted) active.interrupted.complete(null);
      await _release(active);
    }
    await _worker;
    await _frameExtractor.dispose();
  }

  static Future<bool> _hasCover(File file) async {
    final stat = await file.stat();
    return stat.type == FileSystemEntityType.file && stat.size > 0;
  }

  static Future<Directory> _defaultCacheDirectory() async => Directory(
    path.join((await getTemporaryDirectory()).path, 'local_video_covers'),
  );
}

class _CoverJob {
  _CoverJob(
    this.key,
    this.source,
    this.stat,
    this.cached,
    Completer<File?> request,
  ) : requests = [request];

  final String key;
  final File source;
  final FileStat stat;
  final File cached;
  final List<Completer<File?>> requests;
  final interrupted = Completer<Uint8List?>();
  final finished = Completer<void>();
  Future<void>? release;
}

class _MpvFrameExtractor implements LocalVideoFrameExtractor {
  Player? _player;
  Future<void>? _release;
  bool _disposed = false;

  @override
  Future<Uint8List?> capture(File source) async {
    if (_disposed) return null;
    MediaKit.ensureInitialized();
    final player = _player = Player(
      configuration: const PlayerConfiguration(vo: 'null', muted: true),
    );
    final native = player.platform as NativePlayer;
    await native.setProperty('vid', 'auto');
    await native.setProperty('ao', 'null');
    await native.setProperty('sid', 'no');
    await native.setProperty('sub-auto', 'no');
    if (!identical(_player, player)) return null;
    await player.open(
      Media(Uri.file(source.path, windows: Platform.isWindows).toString()),
      play: false,
    );
    while (identical(_player, player)) {
      final duration = double.tryParse(await native.getProperty('duration'));
      if (duration != null && duration.isFinite && duration > 0) {
        await player.seek(
          Duration(milliseconds: math.min(duration * 100, 10000).round()),
        );
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    // Seeking is asynchronous in mpv; wait for a decoded frame before capturing.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    while (identical(_player, player)) {
      if (await native.getProperty('seeking') != 'yes') {
        final bytes = await player.screenshot(
          format: 'image/jpeg',
          includeLibassSubtitles: false,
        );
        if (bytes != null) {
          final cover = await compute(_resizeCover, bytes);
          if (cover != null) return cover;
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return null;
  }

  @override
  Future<void> cancel() {
    final player = _player;
    if (player == null) return _release ?? Future.value();
    _player = null;
    // A screenshot may be awaiting an mpv reply while holding the operation lock.
    // Bypass that lock so timeout/suspend actually stops and disposes the core.
    return _release = (player.platform as NativePlayer).dispose(
      synchronized: false,
    );
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    await cancel();
  }
}

Uint8List? _resizeCover(Uint8List bytes) {
  final frame = image.decodeImage(bytes);
  if (frame == null) return null;
  if (frame.width <= 640 && frame.height <= 640) return bytes;
  final resized = image.copyResize(
    frame,
    width: frame.width >= frame.height ? 640 : null,
    height: frame.height > frame.width ? 640 : null,
    interpolation: image.Interpolation.average,
  );
  return image.encodeJpg(resized, quality: 85);
}
