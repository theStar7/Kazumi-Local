class LocalDanmakuBinding {
  const LocalDanmakuBinding({
    required this.episodeId,
    required this.animeTitle,
    required this.episodeTitle,
  });

  final int episodeId;
  final String animeTitle;
  final String episodeTitle;

  factory LocalDanmakuBinding.fromJson(Map<String, dynamic> json) {
    return LocalDanmakuBinding(
      episodeId: json['episodeId'] as int,
      animeTitle: json['animeTitle'] as String,
      episodeTitle: json['episodeTitle'] as String,
    );
  }

  Map<String, dynamic> toJson() => {
    'episodeId': episodeId,
    'animeTitle': animeTitle,
    'episodeTitle': episodeTitle,
  };
}

enum LocalSubtitleSource { auto, embedded, external }

class LocalSubtitleSettings {
  const LocalSubtitleSettings({
    this.enabled = true,
    this.source = LocalSubtitleSource.auto,
    this.embeddedTrackId,
    this.externalPath,
  });

  final bool enabled;
  final LocalSubtitleSource source;
  final String? embeddedTrackId;
  final String? externalPath;

  factory LocalSubtitleSettings.fromJson(Map<String, dynamic> json) {
    return LocalSubtitleSettings(
      enabled: json['enabled'] as bool? ?? true,
      source: switch (json['source']) {
        'embedded' => LocalSubtitleSource.embedded,
        'external' => LocalSubtitleSource.external,
        _ => LocalSubtitleSource.auto,
      },
      embeddedTrackId: json['embeddedTrackId'] as String?,
      externalPath: json['externalPath'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'source': source.name,
    'embeddedTrackId': embeddedTrackId,
    'externalPath': externalPath,
  };

  LocalSubtitleSettings copyWith({
    bool? enabled,
    LocalSubtitleSource? source,
    String? embeddedTrackId,
    String? externalPath,
    bool clearExternalPath = false,
  }) {
    return LocalSubtitleSettings(
      enabled: enabled ?? this.enabled,
      source: source ?? this.source,
      embeddedTrackId: embeddedTrackId ?? this.embeddedTrackId,
      externalPath: clearExternalPath
          ? null
          : externalPath ?? this.externalPath,
    );
  }
}

class LocalVideo {
  const LocalVideo({
    required this.id,
    required this.path,
    required this.name,
    this.positionMilliseconds = 0,
    this.durationMilliseconds = 0,
    this.danmakuBinding,
    this.subtitleSettings,
  });

  final String id;
  final String path;
  final String name;
  final int positionMilliseconds;
  final int durationMilliseconds;
  final LocalDanmakuBinding? danmakuBinding;
  final LocalSubtitleSettings? subtitleSettings;

  factory LocalVideo.fromJson(Map<String, dynamic> json) {
    final binding = json['danmakuBinding'];
    final subtitles = json['subtitleSettings'];
    return LocalVideo(
      id: json['id'] as String,
      path: json['path'] as String,
      name: json['name'] as String,
      positionMilliseconds: json['positionMilliseconds'] as int? ?? 0,
      durationMilliseconds: json['durationMilliseconds'] as int? ?? 0,
      danmakuBinding: binding == null
          ? null
          : LocalDanmakuBinding.fromJson(binding as Map<String, dynamic>),
      subtitleSettings: subtitles == null
          ? null
          : LocalSubtitleSettings.fromJson(subtitles as Map<String, dynamic>),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'path': path,
    'name': name,
    'positionMilliseconds': positionMilliseconds,
    'durationMilliseconds': durationMilliseconds,
    'danmakuBinding': danmakuBinding?.toJson(),
    'subtitleSettings': subtitleSettings?.toJson(),
  };

  LocalVideo copyWith({
    String? id,
    String? path,
    String? name,
    int? positionMilliseconds,
    int? durationMilliseconds,
    LocalDanmakuBinding? danmakuBinding,
    bool clearDanmakuBinding = false,
    LocalSubtitleSettings? subtitleSettings,
    bool clearSubtitleSettings = false,
  }) {
    return LocalVideo(
      id: id ?? this.id,
      path: path ?? this.path,
      name: name ?? this.name,
      positionMilliseconds: positionMilliseconds ?? this.positionMilliseconds,
      durationMilliseconds: durationMilliseconds ?? this.durationMilliseconds,
      danmakuBinding: clearDanmakuBinding
          ? null
          : danmakuBinding ?? this.danmakuBinding,
      subtitleSettings: clearSubtitleSettings
          ? null
          : subtitleSettings ?? this.subtitleSettings,
    );
  }
}
