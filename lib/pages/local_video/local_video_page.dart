import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:kazumi/bean/appbar/sys_app_bar.dart';
import 'package:kazumi/modules/local_video/local_video.dart';
import 'package:kazumi/modules/local_video/local_video_folder.dart';
import 'package:kazumi/repositories/local_video_repository.dart';
import 'package:kazumi/services/local_video/local_video_cover_service.dart';

class LocalVideoPage extends StatefulWidget {
  const LocalVideoPage({
    super.key,
    required this.repository,
    required this.onPlay,
    this.coverService,
    this.createCoverService,
  });

  final LocalVideoRepository repository;
  final Future<void> Function(List<LocalVideo> videos, String initialVideoId)
  onPlay;
  final LocalVideoCoverService? coverService;
  final LocalVideoCoverService Function()? createCoverService;

  @override
  State<LocalVideoPage> createState() => _LocalVideoPageState();
}

class _LocalVideoPageState extends State<LocalVideoPage> {
  late final LocalVideoCoverService? _coverService;
  String? _folderId;
  bool _busy = false;
  bool _opening = false;
  int _refreshGeneration = 0;
  String? _directoryError;
  final Set<String> _missing = {};
  final Set<String> _missingFolders = {};
  final Map<String, Future<File?>> _covers = {};

  LocalVideoFolder? get _folder =>
      _folderId == null ? null : widget.repository.findFolderById(_folderId!);

  @override
  void initState() {
    super.initState();
    _coverService = widget.coverService ?? widget.createCoverService?.call();
    unawaited(_refresh());
  }

  @override
  void dispose() {
    unawaited(_coverService?.dispose());
    super.dispose();
  }

  Future<void> _refresh({bool scan = false}) async {
    final generation = ++_refreshGeneration;
    final folderId = _folderId;
    final folder = _folder;
    setState(() => _busy = true);
    String? directoryError;
    try {
      if (scan && folder?.isDisk == true) {
        final result = await widget.repository.refreshFolder(folder!.id);
        if (result.failedPaths.isNotEmpty) {
          directoryError = '部分目录或文件无法访问：${result.failedPaths.join('、')}';
        }
      }
      final missing = <String>{};
      final missingFolders = <String>{};
      for (final video in widget.repository.videosIn(folderId)) {
        if ((await File(video.path).stat()).type != FileSystemEntityType.file) {
          missing.add(video.id);
        }
      }
      for (final child in widget.repository.foldersIn(folderId)) {
        if (child.isDisk && !await Directory(child.directoryPath!).exists()) {
          missingFolders.add(child.id);
        }
      }
      if (!mounted || generation != _refreshGeneration) return;
      setState(() {
        _missing
          ..clear()
          ..addAll(missing);
        _missingFolders
          ..clear()
          ..addAll(missingFolders);
        _directoryError = directoryError;
        _covers.clear();
      });
    } catch (error) {
      if (mounted && generation == _refreshGeneration) {
        setState(() => _directoryError = '目录无法访问：$error');
      }
    } finally {
      if (mounted && generation == _refreshGeneration) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _navigate(String? folderId) async {
    if (_busy || _opening) return;
    setState(() {
      _folderId = folderId;
      _directoryError = null;
      _covers.clear();
    });
    await _refresh(scan: true);
  }

  void _message(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _change(Future<void> Function() action) async {
    if (_busy || _opening) return;
    setState(() => _busy = true);
    try {
      await action();
      if (mounted) await _refresh();
    } catch (error) {
      _message('操作失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _import({required bool directory}) async {
    setState(() => _busy = true);
    try {
      final LocalVideoImportResult result;
      if (directory) {
        final path = await FilePicker.platform.getDirectoryPath();
        if (path == null || !mounted) return;
        result = await widget.repository.importDirectory(
          path,
          parentId: _folderId,
        );
      } else {
        final selection = await FilePicker.platform.pickFiles(
          allowMultiple: true,
          type: FileType.custom,
          allowedExtensions: const [
            'mp4',
            'mkv',
            'avi',
            'mov',
            'webm',
            'flv',
            'wmv',
            'm4v',
            'ts',
            'm2ts',
            'mpg',
            'mpeg',
          ],
        );
        if (selection == null || !mounted) return;
        result = await widget.repository.importFiles(
          selection.files.map((file) => file.path).whereType<String>(),
          folderId: _folderId,
        );
      }
      if (!mounted) return;
      await _refresh();
      _message(
        '已导入 ${result.added.length} 个视频，重复 ${result.duplicateCount} 个，忽略 ${result.unsupportedCount} 个非视频文件',
      );
      if (result.failedPaths.isNotEmpty && mounted) {
        await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('部分文件无法访问'),
            content: SingleChildScrollView(
              child: SelectableText(result.failedPaths.join('\n')),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('确定'),
              ),
            ],
          ),
        );
      }
    } catch (error) {
      _message('导入失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _editFolder([LocalVideoFolder? folder]) async {
    var draft = folder?.name ?? '';
    final name = await showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text(folder == null ? '新建文件夹' : '重命名文件夹'),
          content: TextFormField(
            initialValue: draft,
            autofocus: true,
            decoration: const InputDecoration(labelText: '文件夹名称'),
            onChanged: (value) => update(() => draft = value),
            onFieldSubmitted: (value) {
              if (value.trim().isNotEmpty) Navigator.pop(context, value.trim());
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: draft.trim().isEmpty
                  ? null
                  : () => Navigator.pop(context, draft.trim()),
              child: Text(folder == null ? '创建' : '保存'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || name == null) return;
    await _change(() async {
      if (folder == null) {
        await widget.repository.createVirtualFolder(name, parentId: _folderId);
      } else {
        await widget.repository.renameFolder(folder.id, name);
      }
    });
  }

  Future<void> _deleteFolder(LocalVideoFolder folder) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除分类文件夹'),
        content: Text('删除“${folder.name}”及其子分类？视频记录和磁盘文件会保留。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await _change(() => widget.repository.removeFolder(folder.id));
    }
  }

  Future<void> _addExisting() async {
    final folder = _folder!;
    final selected = <String>{};
    final videos = widget.repository.videos;
    final result = await showDialog<List<String>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text('添加已有视频'),
          content: SizedBox(
            width: 440,
            height: 320,
            child: videos.isEmpty
                ? const Center(child: Text('请先导入视频'))
                : ListView.builder(
                    itemCount: videos.length,
                    itemBuilder: (context, index) {
                      final video = videos[index];
                      final added = folder.videoIds.contains(video.id);
                      return CheckboxListTile(
                        title: Text(video.name),
                        subtitle: Text(
                          added ? '已在此文件夹中' : video.path,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        value: added || selected.contains(video.id),
                        onChanged: added
                            ? null
                            : (value) => update(() {
                                if (value == true) {
                                  selected.add(video.id);
                                } else {
                                  selected.remove(video.id);
                                }
                              }),
                      );
                    },
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: selected.isEmpty
                  ? null
                  : () => Navigator.pop(context, selected.toList()),
              child: const Text('添加'),
            ),
          ],
        ),
      ),
    );
    if (result != null && mounted) {
      await _change(
        () => widget.repository.addVideosToFolder(folder.id, result),
      );
    }
  }

  Future<void> _play(LocalVideo video) async {
    if (_busy || _opening) return;
    setState(() => _opening = true);
    var suspended = false;
    try {
      try {
        final file = await File(video.path).open();
        await file.close();
      } on FileSystemException catch (error) {
        if (!mounted) return;
        await _refresh();
        final exists = await File(video.path).exists();
        _message(
          exists ? '文件无法读取，请检查访问权限：${error.message}' : '文件已丢失，请恢复原路径下的文件或重新导入',
        );
        return;
      }
      if (!mounted) return;
      final playlist = widget.repository.playlistInFolder(
        video.id,
        folderId: _folderId,
      );
      await _coverService?.suspend();
      suspended = true;
      if (mounted) await widget.onPlay(playlist, video.id);
    } catch (error) {
      _message('播放失败：$error');
    } finally {
      if (suspended && mounted) _coverService?.resume();
      if (mounted) {
        setState(() => _opening = false);
        await _refresh(scan: true);
      }
    }
  }

  String _time(int milliseconds) {
    final duration = Duration(milliseconds: milliseconds);
    final seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');
    final minutes = (duration.inMinutes % 60).toString().padLeft(2, '0');
    return duration.inHours > 0
        ? '${duration.inHours}:$minutes:$seconds'
        : '$minutes:$seconds';
  }

  Widget _breadcrumbs() {
    final ancestors = <LocalVideoFolder>[];
    var current = _folder;
    while (current != null) {
      ancestors.insert(0, current);
      current = current.parentId == null
          ? null
          : widget.repository.findFolderById(current.parentId!);
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          TextButton(
            onPressed: _busy ? null : () => _navigate(null),
            child: const Text('媒体库'),
          ),
          for (final folder in ancestors) ...[
            const Icon(Icons.chevron_right, size: 18),
            TextButton(
              onPressed: _busy ? null : () => _navigate(folder.id),
              child: Text(folder.name),
            ),
          ],
        ],
      ),
    );
  }

  Widget _folderCard(LocalVideoFolder folder) {
    final colors = Theme.of(context).colorScheme;
    return Card(
      key: ValueKey('folder-${folder.id}'),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: _busy ? null : () => _navigate(folder.id),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AspectRatio(
              aspectRatio: 16 / 9,
              child: ColoredBox(
                color: colors.secondaryContainer,
                child: Icon(
                  folder.isDisk
                      ? Icons.folder_outlined
                      : Icons.folder_copy_outlined,
                  size: 64,
                  color: colors.onSecondaryContainer,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 4, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      folder.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                  if (folder.isVirtual)
                    PopupMenuButton<String>(
                      tooltip: '文件夹操作',
                      enabled: !_busy && !_opening,
                      onSelected: (value) => value == 'rename'
                          ? _editFolder(folder)
                          : _deleteFolder(folder),
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'rename', child: Text('重命名')),
                        PopupMenuItem(value: 'delete', child: Text('删除文件夹')),
                      ],
                    )
                  else
                    const SizedBox(height: 48, width: 8),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                '${widget.repository.videosIn(folder.id).length} 个视频 · ${widget.repository.foldersIn(folder.id).length} 个文件夹',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
              child: Text(
                _missingFolders.contains(folder.id)
                    ? '目录无法访问，记录已保留'
                    : folder.isDisk
                    ? '磁盘文件夹'
                    : '分类文件夹',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: _missingFolders.contains(folder.id)
                      ? colors.error
                      : colors.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _videoCard(LocalVideo video) {
    final binding = video.danmakuBinding;
    final missing = _missing.contains(video.id);
    final colors = Theme.of(context).colorScheme;
    final canRemove = _folder?.isDisk != true;
    Widget placeholder() => ColoredBox(
      color: colors.surfaceContainerHighest,
      child: Center(
        child: Icon(
          missing ? Icons.error_outline : Icons.video_file_outlined,
          size: 42,
          color: colors.onSurfaceVariant,
        ),
      ),
    );
    return Card(
      key: ValueKey('video-${video.id}'),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _play(video),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AspectRatio(
              aspectRatio: 16 / 9,
              child: FutureBuilder<File?>(
                future: _busy
                    ? null
                    : _covers.putIfAbsent(
                        video.id,
                        () => _coverService?.load(video) ?? Future.value(null),
                      ),
                builder: (context, snapshot) => snapshot.data == null
                    ? placeholder()
                    : Image.file(
                        snapshot.data!,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => placeholder(),
                      ),
              ),
            ),
            LinearProgressIndicator(
              value: video.durationMilliseconds <= 0
                  ? 0
                  : (video.positionMilliseconds / video.durationMilliseconds)
                        .clamp(0, 1),
              minHeight: 3,
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 4, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      video.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                  if (binding != null || canRemove)
                    PopupMenuButton<String>(
                      tooltip: '更多操作',
                      enabled: !_busy && !_opening,
                      onSelected: (value) => _change(() async {
                        if (value == 'clear') {
                          await widget.repository.setDanmakuBinding(
                            video.id,
                            null,
                          );
                        } else if (_folderId != null) {
                          await widget.repository.removeVideoFromFolder(
                            _folderId!,
                            video.id,
                          );
                        } else {
                          await widget.repository.remove(video.id);
                        }
                      }),
                      itemBuilder: (_) => [
                        if (binding != null)
                          const PopupMenuItem(
                            value: 'clear',
                            child: Text('清除弹幕关联'),
                          ),
                        if (canRemove)
                          PopupMenuItem(
                            value: 'remove',
                            child: Text(_folderId == null ? '从列表移除' : '从文件夹移除'),
                          ),
                      ],
                    )
                  else
                    const SizedBox(height: 48, width: 8),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                '${_time(video.positionMilliseconds)} / ${_time(video.durationMilliseconds)}',
                maxLines: 1,
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Text(
                binding == null
                    ? '未关联弹幕'
                    : '${binding.animeTitle} · ${binding.episodeTitle}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: colors.onSurfaceVariant),
              ),
            ),
            if (missing)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Text(
                  '文件已丢失，请恢复文件或重新导入',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: colors.error),
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final folders = widget.repository.foldersIn(_folderId);
    final videos = widget.repository.videosIn(_folderId);
    final isDisk = _folder?.isDisk == true;
    return Scaffold(
      appBar: SysAppBar(
        title: const Text('本地视频'),
        leading: _folderId == null
            ? null
            : IconButton(
                tooltip: '返回上级',
                onPressed: _busy ? null : () => _navigate(_folder?.parentId),
                icon: const Icon(Icons.arrow_back),
              ),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: _busy || _opening ? null : () => _refresh(scan: true),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Wrap(
                spacing: 12,
                runSpacing: 8,
                children: [
                  if (!isDisk) ...[
                    FilledButton.icon(
                      onPressed: _busy || _opening
                          ? null
                          : () => _import(directory: false),
                      icon: const Icon(Icons.video_file_outlined),
                      label: const Text('导入视频'),
                    ),
                    FilledButton.tonalIcon(
                      onPressed: _busy || _opening
                          ? null
                          : () => _import(directory: true),
                      icon: const Icon(Icons.folder_open_outlined),
                      label: const Text('导入文件夹'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _busy || _opening ? null : _editFolder,
                      icon: const Icon(Icons.create_new_folder_outlined),
                      label: const Text('新建文件夹'),
                    ),
                  ],
                  if (_folder?.isVirtual == true)
                    OutlinedButton.icon(
                      onPressed: _busy || _opening ? null : _addExisting,
                      icon: const Icon(Icons.playlist_add),
                      label: const Text('添加已有视频'),
                    ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: _breadcrumbs(),
            ),
          ),
          if (_directoryError != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Text(
                _directoryError!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          if (_busy) const LinearProgressIndicator(),
          Expanded(
            child: folders.isEmpty && videos.isEmpty
                ? Center(child: Text(_folderId == null ? '还没有本地视频' : '文件夹为空'))
                : LayoutBuilder(
                    builder: (context, constraints) {
                      final columns = ((constraints.maxWidth - 16) / 250)
                          .floor()
                          .clamp(1, 20);
                      final width =
                          (constraints.maxWidth - 32 - (columns - 1) * 12) /
                          columns;
                      return GridView.builder(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: columns,
                          crossAxisSpacing: 12,
                          mainAxisSpacing: 12,
                          mainAxisExtent: (width - 8) * 9 / 16 + 146,
                        ),
                        itemCount: folders.length + videos.length,
                        itemBuilder: (context, index) => index < folders.length
                            ? _folderCard(folders[index])
                            : _videoCard(videos[index - folders.length]),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
