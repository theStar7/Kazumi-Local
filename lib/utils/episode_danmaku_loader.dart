import 'package:kazumi/modules/danmaku/danmaku_module.dart';
import 'package:kazumi/utils/async_session.dart';

/// A manual choice and an automatic restore share one request sequence.
/// Null means the request no longer belongs to the current video/choice.
class EpisodeDanmakuLoader {
  EpisodeDanmakuLoader(this.fetch);

  final Future<List<DanmakuEntry>> Function(int episodeId) fetch;
  final AsyncSessionOwner _requests = AsyncSessionOwner();
  bool isLoading = false;

  Future<List<DanmakuEntry>?> load(
    int episodeId, {
    bool Function()? canApply,
  }) async {
    final request = _requests.begin();
    isLoading = true;
    try {
      final result = await fetch(episodeId);
      if (request.isStale || canApply?.call() == false) return null;
      return result;
    } catch (_) {
      if (request.isStale || canApply?.call() == false) return null;
      rethrow;
    } finally {
      if (request.isActive) isLoading = false;
    }
  }

  void cancel() {
    _requests.cancel();
    isLoading = false;
  }

  void close() {
    _requests.close();
    isLoading = false;
  }
}
