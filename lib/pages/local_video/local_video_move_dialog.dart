import 'package:flutter/material.dart';
import 'package:kazumi/modules/local_video/local_video_folder.dart';
import 'package:kazumi/repositories/local_video_repository.dart';

class LocalVideoMoveDestination {
  const LocalVideoMoveDestination(this.folderId);
  final String? folderId;
}

class LocalVideoMoveDialog extends StatefulWidget {
  const LocalVideoMoveDialog({
    super.key,
    required this.repository,
    required this.initialFolderId,
    required this.movingFolderId,
    required this.canMove,
  });
  final LocalVideoRepository repository;
  final String? initialFolderId;
  final String? movingFolderId;
  final bool Function(String?) canMove;

  @override
  State<LocalVideoMoveDialog> createState() => _LocalVideoMoveDialogState();
}

class _LocalVideoMoveDialogState extends State<LocalVideoMoveDialog> {
  late String? _folderId = widget.initialFolderId;

  @override
  Widget build(BuildContext context) {
    final ancestors = <LocalVideoFolder>[];
    var folder = _folderId == null
        ? null
        : widget.repository.findFolderById(_folderId!);
    while (folder != null) {
      ancestors.insert(0, folder);
      folder = folder.parentId == null
          ? null
          : widget.repository.findFolderById(folder.parentId!);
    }
    final children = widget.repository
        .foldersIn(_folderId)
        .where((child) => child.id != widget.movingFolderId)
        .toList();
    return AlertDialog(
      title: const Text('移动到文件夹'),
      content: SizedBox(
        width: 440,
        height: 360,
        child: Column(
          children: [
            Row(
              children: [
                IconButton(
                  tooltip: '返回上级文件夹',
                  onPressed: _folderId == null
                      ? null
                      : () => setState(() {
                          _folderId = widget.repository
                              .findFolderById(_folderId!)
                              ?.parentId;
                        }),
                  icon: const Icon(Icons.arrow_back),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        TextButton(
                          key: const ValueKey('move-choice-root'),
                          onPressed: () => setState(() => _folderId = null),
                          child: const Text('媒体库'),
                        ),
                        for (final ancestor in ancestors) ...[
                          const Icon(Icons.chevron_right, size: 18),
                          TextButton(
                            onPressed: () =>
                                setState(() => _folderId = ancestor.id),
                            child: Text(ancestor.name),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
            const Divider(),
            Expanded(
              child: children.isEmpty
                  ? const Center(child: Text('没有子文件夹'))
                  : ListView.builder(
                      itemCount: children.length,
                      itemBuilder: (_, index) {
                        final child = children[index];
                        return ListTile(
                          key: ValueKey('move-choice-${child.id}'),
                          leading: const Icon(Icons.folder_outlined),
                          title: Text(
                            child.name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => setState(() => _folderId = child.id),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: widget.canMove(_folderId)
              ? () =>
                    Navigator.pop(context, LocalVideoMoveDestination(_folderId))
              : null,
          child: const Text('移动到此处'),
        ),
      ],
    );
  }
}
