import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/pages/local_video/local_video_page.dart';
import 'package:kazumi/pages/video/video_playback_args.dart';
import 'package:kazumi/repositories/local_video_repository.dart';
import 'package:kazumi/services/local_video/local_video_cover_service.dart';

final localVideoModule = createModule(
  path: '/local',
  register: (c) {
    c.route(
      '/',
      child: (context, state) => LocalVideoPage(
        repository: inject<LocalVideoRepository>(),
        createCoverService: LocalVideoCoverService.new,
        onPlay: (videos, initialVideoId) async {
          await context.pushNamed(
            '/video/',
            arguments: LocalVideoPlaybackArgs(
              videos: videos,
              initialVideoId: initialVideoId,
            ),
          );
        },
      ),
    );
  },
);

