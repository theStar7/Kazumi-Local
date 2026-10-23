import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:kazumi/modules/local_video/local_video.dart';
import 'package:kazumi/services/player/subtitle_backend.dart';
import 'package:kazumi/utils/async_serial_queue.dart';
import 'package:path/path.dart' as path;

class _SubtitleBinding {
  _SubtitleBinding(
    this.backend,
    this.readSettings,
    this.saveSettings,
    this.canApply,
  );

  final SubtitleBackend backend;
  final LocalSubtitleSettings? Function() readSettings;
  final Future<void> Function(LocalSubtitleSettings) saveSettings;
  final bool Function() canApply;
  final queue = AsyncSerialQueue();
  StreamSubscription<void>? subscription;
  bool active = true;
  bool restored = false;
  int version = 0;
  LocalSubtitleSettings wanted = const LocalSubtitleSettings();
}

class _StaleSubtitleOperation implements Exception {}

class PlayerSubtitleController extends ChangeNotifier {
  _SubtitleBinding? _binding;
  bool _disposed = false;
  bool _ready = false;
  bool _busy = false;
  List<SubtitleTrackInfo> _tracks = const [];
  LocalSubtitleSettings _settings = const LocalSubtitleSettings();
  String? _message;

  bool get ready => _ready;
  bool get busy => _busy;
  List<SubtitleTrackInfo> get tracks => _tracks;
  LocalSubtitleSettings get settings => _settings;
  String? get message => _message;

  void bind(
    SubtitleBackend backend, {
    required LocalSubtitleSettings? Function() readSettings,
    required Future<void> Function(LocalSubtitleSettings) saveSettings,
    required bool Function() canApply,
  }) {
    detach();
    if (_disposed) return;
    final binding = _binding = _SubtitleBinding(
      backend,
      readSettings,
      saveSettings,
      canApply,
    );
    binding.subscription = backend.changes.listen((_) => unawaited(refresh()));
    unawaited(refresh());
  }

  bool _current(_SubtitleBinding binding, int version) =>
      !_disposed &&
      identical(_binding, binding) &&
      binding.active &&
      binding.version == version &&
      binding.canApply();

  void _check(_SubtitleBinding binding, int version) {
    if (!_current(binding, version)) throw _StaleSubtitleOperation();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _updateTracks(SubtitleSnapshot snapshot) {
    _tracks = List.unmodifiable(
      snapshot.tracks.where((track) => track.externalPath == null),
    );
    _ready = snapshot.ready;
  }

  Future<void> refresh() async {
    final binding = _binding;
    if (binding == null) return;
    final version = binding.version;
    await binding.queue.run(() async {
      if (!_current(binding, version)) return;
      try {
        final snapshot = await binding.backend.read();
        _check(binding, version);
        _updateTracks(snapshot);
        if (snapshot.ready && !binding.restored) {
          binding.restored = true;
          _busy = true;
          _notify();
          final saved = binding.readSettings() ?? const LocalSubtitleSettings();
          try {
            await _apply(binding, version, saved);
            _check(binding, version);
            _settings = saved;
          } on _StaleSubtitleOperation {
            rethrow;
          } catch (_) {
            final fallback = saved.copyWith(source: LocalSubtitleSource.auto);
            await _apply(binding, version, fallback);
            _check(binding, version);
            _settings = fallback;
            _message = '无法恢复已保存的字幕，请重新选择';
          }
          binding.wanted = _settings;
        }
      } on _StaleSubtitleOperation {
        return;
      } catch (_) {
        if (_current(binding, version)) _message = '读取字幕轨道失败';
      } finally {
        if (_current(binding, version)) {
          _busy = false;
          _notify();
        }
      }
    });
  }

  Future<void> selectDefault() => _change(
    (settings) =>
        settings.copyWith(enabled: true, source: LocalSubtitleSource.auto),
  );

  Future<void> selectEmbedded(String id) => _change(
    (settings) => settings.copyWith(
      enabled: true,
      source: LocalSubtitleSource.embedded,
      embeddedTrackId: id,
    ),
  );

  Future<void> selectExternal() => _change(
    (settings) =>
        settings.copyWith(enabled: true, source: LocalSubtitleSource.external),
  );

  Future<void> setEnabled(bool enabled) =>
      _change((settings) => settings.copyWith(enabled: enabled));

  Future<void> removeExternal() => _change(
    (settings) => settings.copyWith(
      source: settings.source == LocalSubtitleSource.external
          ? LocalSubtitleSource.auto
          : settings.source,
      clearExternalPath: true,
    ),
  );

  Future<void> pickExternal(Future<String?> Function() pick) async {
    final binding = _binding;
    if (binding == null || !_ready) return;
    final version = binding.version;
    try {
      final selected = await pick();
      if (selected == null || !_current(binding, version)) return;
      await _change(
        (settings) => settings.copyWith(
          enabled: true,
          source: LocalSubtitleSource.external,
          externalPath: path.windows.normalize(path.windows.absolute(selected)),
        ),
      );
    } catch (_) {
      if (_current(binding, version)) {
        _message = '选择字幕文件失败';
        _notify();
      }
    }
  }

  Future<void> _change(
    LocalSubtitleSettings Function(LocalSubtitleSettings) update,
  ) async {
    final binding = _binding;
    if (binding == null || !_ready || !binding.canApply()) return;
    final version = ++binding.version;
    final target = binding.wanted = update(binding.wanted);
    _busy = true;
    _message = null;
    _notify();
    await binding.queue.run(() async {
      if (!_current(binding, version)) return;
      try {
        await _apply(binding, version, target);
        _check(binding, version);
        _settings = target;
        try {
          await binding.saveSettings(target);
        } catch (_) {
          if (_current(binding, version)) _message = '已切换，保存失败';
        }
      } on _StaleSubtitleOperation {
        return;
      } catch (_) {
        if (_current(binding, version)) {
          // A removed external track receives a new ID when restored. Reapply
          // the previous preference, rather than selecting its obsolete ID.
          try {
            await _apply(binding, version, _settings);
          } catch (_) {}
          if (_current(binding, version)) {
            binding.wanted = _settings;
            _message = '字幕切换失败，请检查字幕文件或重新选择';
          }
        }
      } finally {
        if (_current(binding, version)) {
          _busy = false;
          _notify();
        }
      }
    });
  }

  Future<void> _apply(
    _SubtitleBinding binding,
    int version,
    LocalSubtitleSettings target,
  ) async {
    _check(binding, version);
    var snapshot = await binding.backend.read();
    _check(binding, version);
    String selected;
    if (!target.enabled) {
      selected = 'no';
    } else {
      switch (target.source) {
        case LocalSubtitleSource.auto:
          // sid=auto may otherwise prefer an already loaded external file.
          await _prune(binding, version, snapshot, null);
          selected = 'auto';
        case LocalSubtitleSource.embedded:
          selected = target.embeddedTrackId ?? '';
          if (!snapshot.tracks.any(
            (track) => track.id == selected && track.externalPath == null,
          )) {
            throw StateError('Embedded subtitle no longer exists');
          }
        case LocalSubtitleSource.external:
          final filePath = target.externalPath;
          if (filePath == null ||
              !const [
                '.srt',
                '.ass',
                '.ssa',
                '.vtt',
              ].contains(path.windows.extension(filePath).toLowerCase())) {
            throw StateError('Unsupported subtitle file');
          }
          bool matches(SubtitleTrackInfo track) =>
              track.externalPath != null &&
              subtitlePathIdentity(track.externalPath!) ==
                  subtitlePathIdentity(filePath);
          if (!snapshot.tracks.any(matches)) {
            final file = await File(filePath).open();
            await file.close();
            _check(binding, version);
            await binding.backend.addExternal(filePath);
            _check(binding, version);
            snapshot = await binding.backend.read();
            _check(binding, version);
            if (!snapshot.tracks.any(matches) ||
                !snapshot.tracks.any(
                  (track) => matches(track) && track.id == snapshot.selectedId,
                )) {
              throw StateError('Native subtitle loading failed');
            }
          }
          selected = snapshot.tracks.firstWhere(matches).id;
      }
    }
    _check(binding, version);
    await binding.backend.select(selected);
    _check(binding, version);
    snapshot = await binding.backend.read();
    _check(binding, version);
    if (selected != 'auto' && snapshot.selectedId != selected) {
      throw StateError('Native subtitle selection failed');
    }
    await _prune(binding, version, snapshot, target.externalPath);
    _check(binding, version);
    _updateTracks(snapshot);
  }

  Future<void> _prune(
    _SubtitleBinding binding,
    int version,
    SubtitleSnapshot snapshot,
    String? keepPath,
  ) async {
    for (final track in snapshot.tracks) {
      if (track.externalPath == null ||
          (keepPath != null &&
              subtitlePathIdentity(track.externalPath!) ==
                  subtitlePathIdentity(keepPath))) {
        continue;
      }
      _check(binding, version);
      await binding.backend.remove(track.id);
    }
  }

  void detach() {
    final binding = _binding;
    _binding = null;
    if (binding != null) {
      binding.active = false;
      unawaited(binding.subscription?.cancel());
    }
    _ready = false;
    _busy = false;
    _tracks = const [];
    _settings = const LocalSubtitleSettings();
    _message = null;
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    detach();
    super.dispose();
  }
}
