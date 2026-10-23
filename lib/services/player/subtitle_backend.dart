import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as path;

class SubtitleTrackInfo {
  const SubtitleTrackInfo({
    required this.id,
    this.title,
    this.language,
    this.codec,
    this.externalPath,
  });

  final String id;
  final String? title;
  final String? language;
  final String? codec;
  final String? externalPath;

  String get label => title?.isNotEmpty == true ? title! : '字幕轨道 $id';
}

class SubtitleSnapshot {
  const SubtitleSnapshot({
    required this.ready,
    required this.tracks,
    required this.selectedId,
  });

  final bool ready;
  final List<SubtitleTrackInfo> tracks;
  final String selectedId;
}

abstract interface class SubtitleBackend {
  Stream<void> get changes;
  Future<SubtitleSnapshot> read();
  Future<void> select(String id);
  Future<void> addExternal(String filePath);
  Future<void> remove(String id);
}

/// Reads mpv's actual track list: this media-kit version reports a requested
/// external track in PlayerState even when mpv rejects the sub-add command.
class NativeSubtitleBackend implements SubtitleBackend {
  NativeSubtitleBackend(this.player);

  final Player player;
  NativePlayer get _native => player.platform as NativePlayer;

  @override
  Stream<void> get changes => player.stream.tracks.map((_) {});

  @override
  Future<SubtitleSnapshot> read() async {
    final count =
        int.tryParse(await _native.getProperty('track-list/count')) ?? 0;
    final tracks = <SubtitleTrackInfo>[];
    for (var index = 0; index < count; index++) {
      final prefix = 'track-list/$index';
      if (await _native.getProperty('$prefix/type') != 'sub') continue;
      final external = await _native.getProperty('$prefix/external') == 'yes';
      tracks.add(
        SubtitleTrackInfo(
          id: await _native.getProperty('$prefix/id'),
          title: await _native.getProperty('$prefix/title'),
          language: await _native.getProperty('$prefix/lang'),
          codec: await _native.getProperty('$prefix/codec'),
          externalPath: external
              ? await _native.getProperty('$prefix/external-filename')
              : null,
        ),
      );
    }
    return SubtitleSnapshot(
      ready: count > 0,
      tracks: tracks,
      selectedId: await _native.getProperty('sid'),
    );
  }

  @override
  Future<void> select(String id) async {
    await player.setSubtitleTrack(
      id == 'auto' ? SubtitleTrack.auto() : SubtitleTrack(id, null, null),
    );
    // sid resolves "auto" to a track ID; options/sid preserves the requested
    // mode and lets us detect a silently rejected native property change.
    if (await _native.getProperty('options/sid') != id) {
      throw StateError('Native subtitle selection was rejected');
    }
  }

  @override
  Future<void> addExternal(String filePath) => player.setSubtitleTrack(
    SubtitleTrack.uri(
      Uri.file(filePath, windows: true).toString(),
      title: path.windows.basename(filePath),
    ),
  );

  @override
  Future<void> remove(String id) async {
    await _native.command(['sub-remove', id]);
    if ((await read()).tracks.any((track) => track.id == id)) {
      throw StateError('Native subtitle removal was rejected');
    }
  }
}

String subtitlePathIdentity(String value) {
  final uri = Uri.tryParse(value);
  final filePath = uri?.scheme == 'file'
      ? uri!.toFilePath(windows: true)
      : value;
  return path.windows.normalize(filePath).toLowerCase();
}
