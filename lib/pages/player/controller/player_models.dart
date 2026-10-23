import 'package:kazumi/services/video_source/video_source_format.dart';
import 'package:kazumi/modules/local_video/local_video.dart';

class PlaybackInitParams {
  final String videoUrl;
  final int offset;
  final bool isLocalPlayback;
  final bool nativeSubtitles;
  final LocalSubtitleSettings? Function()? readSubtitleSettings;
  final Future<void> Function(LocalSubtitleSettings)? saveSubtitleSettings;
  final bool Function()? canApplySubtitles;
  final VideoSourceFormat videoSourceFormat;
  final int bangumiId;
  final String pluginName;
  final int episode;
  final int danmakuEpisodeNumber;
  final String pageUrl;

  /// Parsed title number online, downloaded episode number offline.
  final int? sortNumber;
  final Map<String, String> httpHeaders;
  final bool adBlockerEnabled;
  final String episodeTitle;
  final String referer;
  final int currentRoad;
  final String? coverUrl;
  final String? bangumiName;

  const PlaybackInitParams({
    required this.videoUrl,
    required this.offset,
    required this.isLocalPlayback,
    this.nativeSubtitles = false,
    this.readSubtitleSettings,
    this.saveSubtitleSettings,
    this.canApplySubtitles,
    required this.bangumiId,
    required this.pluginName,
    required this.episode,
    required this.danmakuEpisodeNumber,
    required this.httpHeaders,
    required this.adBlockerEnabled,
    required this.episodeTitle,
    required this.referer,
    required this.currentRoad,
    this.videoSourceFormat = VideoSourceFormat.auto,
    this.pageUrl = '',
    this.sortNumber,
    this.coverUrl,
    this.bangumiName,
  });
}

class SyncPlayChatMessage {
  final String username;
  final String message;
  final bool fromRemote;
  final DateTime time;

  SyncPlayChatMessage({
    required this.username,
    required this.message,
    this.fromRemote = true,
    DateTime? time,
  }) : time = time ?? DateTime.now();
}
