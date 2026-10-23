import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:kazumi/bean/dialog/adaptive_bottom_sheet.dart';
import 'package:kazumi/bean/dialog/material_bottom_sheet.dart';
import 'package:kazumi/bean/widget/split_list_row.dart';
import 'package:kazumi/modules/local_video/local_video.dart';
import 'package:kazumi/pages/player/controller/player_subtitle_controller.dart';
import 'package:path/path.dart' as path;

Future<void> showPlayerSubtitleSheet(
  BuildContext context, {
  required PlayerSubtitleController controller,
  required bool Function() canApply,
}) async {
  await showAdaptiveBottomSheet<void>(
    context: context,
    builder: (context) =>
        PlayerSubtitleSheet(controller: controller, canApply: canApply),
  );
}

class PlayerSubtitleSheet extends StatefulWidget {
  const PlayerSubtitleSheet({
    super.key,
    required this.controller,
    required this.canApply,
    this.pickFile,
  });

  final PlayerSubtitleController controller;
  final bool Function() canApply;
  final Future<String?> Function()? pickFile;

  @override
  State<PlayerSubtitleSheet> createState() => _PlayerSubtitleSheetState();
}

class _PlayerSubtitleSheetState extends State<PlayerSubtitleSheet> {
  bool _wasReady = false;
  bool _disconnected = false;
  bool _picking = false;

  bool get _canChange =>
      !_disconnected &&
      !_picking &&
      widget.controller.ready &&
      !widget.controller.busy &&
      widget.canApply();

  @override
  void initState() {
    super.initState();
    _wasReady = widget.controller.ready;
    widget.controller.addListener(_changed);
  }

  @override
  void didUpdateWidget(PlayerSubtitleSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
      _wasReady = widget.controller.ready;
      _disconnected = false;
    }
  }

  void _changed() {
    if (_wasReady && !widget.controller.ready && !_disconnected) {
      _disconnected = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final route = ModalRoute.of(context);
        if (route is ModalBottomSheetRoute && route.isCurrent) {
          Navigator.of(context).pop();
        }
      });
    }
    _wasReady = _wasReady || widget.controller.ready;
    setState(() {});
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    super.dispose();
  }

  void _apply(Future<void> Function() action) {
    if (_canChange) unawaited(action());
  }

  Future<String?> _pickFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['srt', 'ass', 'ssa', 'vtt'],
      allowMultiple: false,
    );
    return result?.files.single.path;
  }

  Future<void> _chooseFile() async {
    if (!_canChange) return;
    setState(() => _picking = true);
    try {
      await widget.controller.pickExternal(() async {
        final selected = await (widget.pickFile ?? _pickFile)();
        return mounted && !_disconnected && widget.canApply() ? selected : null;
      });
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  void _select(String? value) {
    if (value == null) return;
    _apply(
      () => switch (value) {
        'auto' => widget.controller.selectDefault(),
        'external' => widget.controller.selectExternal(),
        _ => widget.controller.selectEmbedded(value),
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final settings = controller.settings;
    final enabled = _canChange;
    final selected = switch (settings.source) {
      LocalSubtitleSource.auto => 'auto',
      LocalSubtitleSource.embedded => settings.embeddedTrackId,
      LocalSubtitleSource.external => 'external',
    };
    final externalPath = settings.externalPath;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MaterialBottomSheetHeader(
          title: '字幕',
          onClose: () {
            final route = ModalRoute.of(context);
            if (route is ModalBottomSheetRoute && route.isCurrent) {
              Navigator.of(context).pop();
            }
          },
        ),
        Flexible(
          child: SingleChildScrollView(
            padding: materialBottomSheetContentPadding,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SplitListGroup(
                  children: [
                    SwitchListTile(
                      title: const Text('显示字幕'),
                      value: settings.enabled,
                      onChanged: enabled
                          ? (value) =>
                                _apply(() => controller.setEnabled(value))
                          : null,
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                if (_disconnected || !widget.canApply())
                  const Padding(
                    padding: EdgeInsets.only(bottom: 16),
                    child: Text('当前视频已关闭'),
                  )
                else if (!controller.ready)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 16),
                    child: Text('正在读取字幕轨道…'),
                  ),
                if (controller.message != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Text(
                      controller.message!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                RadioGroup<String>(
                  groupValue: selected,
                  onChanged: _select,
                  child: SplitListGroup(
                    children: [
                      RadioListTile<String>(
                        value: 'auto',
                        enabled: enabled,
                        title: const Text('跟随视频默认字幕'),
                        subtitle: const Text('使用视频默认字幕轨道'),
                      ),
                      for (final track in controller.tracks)
                        RadioListTile<String>(
                          value: track.id,
                          enabled: enabled,
                          title: Text(track.label),
                          subtitle: Text(
                            [
                              if (track.language?.isNotEmpty == true)
                                track.language!,
                              if (track.codec?.isNotEmpty == true) track.codec!,
                            ].join(' · '),
                          ),
                        ),
                      if (externalPath != null)
                        RadioListTile<String>(
                          value: 'external',
                          enabled: enabled,
                          title: Text(path.windows.basename(externalPath)),
                          subtitle: const Text('外部字幕'),
                        ),
                    ],
                  ),
                ),
                if (controller.ready && controller.tracks.isEmpty)
                  const Padding(
                    padding: EdgeInsets.only(top: 16),
                    child: Text('此视频没有内嵌字幕'),
                  ),
                const SizedBox(height: 16),
                if (externalPath == null)
                  TextButton.icon(
                    onPressed: enabled ? _chooseFile : null,
                    icon: const Icon(Icons.add_rounded),
                    label: const Text('添加外部字幕'),
                  )
                else
                  Wrap(
                    spacing: 8,
                    children: [
                      TextButton.icon(
                        onPressed: enabled ? _chooseFile : null,
                        icon: const Icon(Icons.folder_open_rounded),
                        label: const Text('替换文件'),
                      ),
                      TextButton.icon(
                        onPressed: enabled
                            ? () => _apply(controller.removeExternal)
                            : null,
                        icon: const Icon(Icons.link_off_rounded),
                        label: const Text('移除关联'),
                      ),
                    ],
                  ),
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text('支持 SRT、ASS、SSA、VTT'),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
