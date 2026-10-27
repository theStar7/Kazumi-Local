# 本地视频验证记录

## 发布前复验（2026-10-28，v2.4.1-local.1）

- 发布目标为 `theStar7/Kazumi-Local`，应用版本更新为 `2.4.1+20402`。本次收录本地视频库、字幕、文件夹与封面、当前层连播、应用内拖放与菜单移动，以及 README 使用说明。
- 完整 `flutter test --no-pub --reporter expanded`：**397 通过 / 1 项既有 Windows 文件链接权限跳过**，退出码 0。
- `flutter analyze --no-pub --no-fatal-infos --fatal-warnings`：退出码 0，无 error、warning，保留既有 **17 项 info**。
- `flutter build windows --release --no-pub --dart-define-from-file=config/dart_defines.local.json`：**成功，退出码 0**，约 94.3 秒；使用本机编译配置，不提交凭据文件。仍有既有 NuGet 提示和 `webview_windows` CMP0175 开发警告。
- 独立只读代码复核未发现阻断发布的缺陷，覆盖迁移、引用与删除、拖放生命周期、回归测试及文档一致性。
- Windows x64 便携包保留整个 Release 目录的运行文件，并附项目许可证、第三方许可与 SHA-256 校验文件；本次不执行上游代码签名流程。
- 本轮为自动测试、静态检查与正式构建复验；未重新执行完整 exe 的人工文件选择、拖动、全屏和跨重启验收，也未验收真实弹幕服务。原生封面与字幕的既有验证范围见下方历史记录。
- 本轮日志位于已忽略的 `.dart_tool/release_20261028/`，不进入源码提交或发布附件。

## 应用内拖放整理与快捷移动（2026-10-24，PlanA）

基线提交 `41622f2`；当前分支 `PlanA`。本轮将导入后的层级改为应用内结构，加入显式根层引用、旧目录迁移、视频/文件夹移动，以及长按拖放和右下角菜单目标选择。软件整理不修改源媒体路径或文件；主动重新导入补充新内容，进入和刷新不扫描目录。

### 自动测试与检查

- 修改前完整测试：354 通过 / 1 项 Windows 文件链接权限跳过，退出码 0。
- 数据层独立复跑：53 通过 / 1 跳过，退出码 0；包含新增 24 项迁移和移动回归。覆盖 Hive 重开、并发/失败迁移、根层显隐、多位置引用、循环限制、目标/来源写入失败、首次来源导入中断重试、三种加入入口后移出不被重导恢复，以及无文件系统写入。日志：`.dart_tool/local_video_move_validation/data_tests.log`。
- 最终完整 `flutter test --no-pub --reporter expanded`：**397 通过 / 1 项既有权限跳过**，退出码 0，约 23 秒。相对基线新增 24 项数据回归和 19 项页面回归。日志：`.dart_tool/local_video_move_validation/unit_tests.log`。
- 页面 **38 项**通过，涵盖长按移入、面包屑及固定区域移出、菜单分层选择与取消、当前位置/自身/后代限制、分类操作、初始化失败重试、原目录缺失后的逻辑整理，以及窗口关闭和当前层播放列表回归。拖动额外验证同帧双指仅一个拖动、第二指不影响滚动、来源卡片回收后继续跟踪、静止指针自动滚动后释放到当前可见目录（旧目标仍挂载/已回收）、取消及页面销毁停止滚动；相关缺口均先复现失败再修复。
- 最终 `dart analyze`：退出码 0，无 error、warning，保留原有 **17 项 info**。日志：`.dart_tool/local_video_move_validation/analyze.log`。
- `scripts/preview_local_video_library.dart`：**2 项通过**，退出码 0。已生成并复核 360×900 / 1280×900 下根层、分类、导入目录、移动弹窗和拖动状态共 **10 张截图**，无布局溢出；窄窗口拖动预览随指针靠边时可部分超出窗口。结果为 `.dart_tool/local_video_move_validation/library_*.png`，日志为同目录 `preview.log`。
- 数据与页面的规格/质量复审均通过；`git diff --check` 和测试脚本 PowerShell 语法检查通过。原 `local_video.dart`、`player_item.dart`、`video_controller.dart`、`video_playback_args.dart` 和封面服务源代码相对基线不变。
- 最终 `flutter build windows --release --no-pub`：**成功，退出码 0**，约 77.1 秒。程序为 `build/windows/x64/runner/Release/kazumi.exe`，`data/app.so` 同步更新；需保留整个 Release 目录运行。日志：`.dart_tool/local_video_move_validation/build_release.log`。仍有既有 NuGet 提示和 `webview_windows` CMP0175 开发警告；未创建安装包，弹幕凭据继续遵循使用说明的现有配置边界。
- 最终 `libmpv-2.dll` SHA-256 为 `361e3a306707454a24e7d3558b2eb7a9ccc23a4f5ed396fe7e77f0a44908eda5`，与原生验证一致。
- 当前分支保留 **PlanA**。对照 `.dart_tool/local_video_move_validation/starting_refs.txt`，所有本地分支及远端跟踪引用均不变，`kazumi-local/main` 仍为 `41622f28987b9fc5439b8d59885a06fa6736dda0`；本轮未提交、合并或推送。既有 `.vs/` 未改动。

### 原生封面复核

重新运行 `scripts/verify_local_video_covers.dart`：13 项断言通过，退出码 0。使用自制带音轨 MP4、实际封面服务和现有 Windows mpv，检查缓存、源文件变化、暂停释放、损坏视频和额外可见窗口数 0。日志：`.dart_tool/local_video_move_validation/native_covers.log`；机器报告仍由脚本输出到 `.dart_tool/local_video_library_validation/cover_report.json`。本轮没有改封面服务；这不代表人工扬声器听音或完整应用操作验收。

### 操作验证边界

界面验证使用控件测试和隔离合成素材截图，不读取用户媒体库。完整 Release exe 的人工拖动、真实文件选择、全屏和跨重启操作本轮尚未执行；自动测试、Hive 持久化测试和原生抽帧各自只证明对应范围。

## 文件夹、封面卡片与连播（2026-10-24）

本轮在既有未提交本地视频/字幕功能上扩展，继续使用当前 `feature/windows-local-video` 工作目录。新增独立 `localVideoFolders` Hive 存储、磁盘目录树、应用内分类引用、封面缓存、响应式卡片及当前层播放队列。没有移动、复制或删除用户媒体，没有新增运行时依赖，也没有提交或推送代码。

### 自动测试与静态检查

- 完整 `flutter test --no-pub --reporter expanded`：**354 项通过，1 项因现有 Windows 文件链接权限限制跳过**，退出码 0。日志：`.dart_tool/local_video_library_validation/unit_tests.log`。
- 文件夹测试覆盖 Hive 重开、旧记录进度/字幕/弹幕保留、多分类引用、重复和重叠导入、进入时只刷新当前层、目录不可访问、缺失记录保留，以及未纳入磁盘入口的视频在根层可达。
- 封面服务 **14 项**测试覆盖路径/大小/修改时间失效、并发去重与串行处理、失败占位、暂停/恢复、10 秒超时、源文件在抽帧中变化及销毁清理。
- 页面 **19 项**测试通过，涵盖分类嵌套/重命名/删除、添加已有视频、取消当前分类引用、面包屑/返回、磁盘刷新、封面等待/成功/失败与服务生命周期；360/1280 宽度布局无溢出，窗口关闭按钮仍调用既有关闭通道。新增按钮与目录卡片测试在实现前按预期失败，之后通过。
- 自动连播 **4 项**回归使用真实 `PlayerItem` 完成定时器和视频控制器，只替换原生媒体初始化及系统音频：默认开启，从当前层中间起播按自然顺序进入下一集，关闭后不切集，末尾停止且不循环。子目录和其他分类不混入列表。
- `dart analyze`：退出码 0，**无 error、warning，保留原有 17 项 info**；本轮新增脚本单独分析无问题。日志：`.dart_tool/local_video_library_validation/analyze.log`。
- 数据、封面和页面分别通过只读规格/代码复审。`git diff --check` 通过；独立数据测试脚本已加入文件夹测试，PowerShell 语法检查通过。
- 对照本轮开始前的快照，原 `player_item.dart`、`video_controller.dart` 和既有 `local_video_playback_test.dart` 的 SHA-256 完全一致，原字幕/进度/弹幕及播放器切集流程没有被本轮改写。

### 原生封面验证

`flutter test --no-pub scripts/verify_local_video_covers.dart --reporter expanded`：**13 项断言通过**，退出码 0，结果见 `.dart_tool/local_video_library_validation/cover_report.json`，日志见同目录 `native_covers.log`。

- 使用自制带音轨 MP4，实际调用封面服务及 Release 中的 media-kit/mpv。中文、空格和 `#` 路径可用，画面被缩放为 640×360 JPEG。
- 红/蓝画面的像素检查及视觉复核通过；并发请求复用缓存，命中不重写 JPEG，替换源文件后缓存键和封面更新，源媒体字节保持不变。
- 暂停期间缓存可读、新任务等待；实际原生任务尚未完成时暂停，可在 2 秒以内结束并释放，再恢复处理。损坏视频返回空封面。
- 后端设置 `muted=true`、`ao=null`、`vo=null`；初始化探针实际读取音频/视频输出属性确认均为 `null`。对当前进程持续枚举可见窗口，**额外窗口为 0**。这些是后端/窗口检查，未进行人工扬声器听音。
- 本次构建的 `libmpv-2.dll` SHA-256 仍为 `361e3a306707454a24e7d3558b2eb7a9ccc23a4f5ed396fe7e77f0a44908eda5`，与原生验证所用库一致。

生成素材、原生封面、报告和日志只写入已忽略的 `.dart_tool/local_video_library_validation/`；ffmpeg 仅用于制作验证素材，不是应用运行依赖。可通过 `COVER_FFMPEG`、`COVER_MPV_DLL` 指定验证工具位置。

### 页面截图与完整应用操作边界

`flutter test --no-pub scripts/preview_local_video_library.dart --reporter expanded`：**2 项通过**，生成并复核根层、分类、磁盘目录在 360×900 / 1280×900 下的 **6 张截图**。脚本加载真实中文及图标字体，用独立临时设置、合成记录和模拟封面服务返回上述原生红/蓝 JPEG；检查目录刷新完成后再截图。结果为 `library_360_*.png`、`library_1280_*.png`，日志为 `preview.log`。

完整 Release exe 的人工文件选择、窗口/全屏操作、跨重启及实播全流程 **本轮未执行**。页面控件测试、Hive 重开测试、完成事件回归和原生抽帧分别证明对应层，不将它们当成完整应用人工验收。下方历史验收清单仍保留其原有状态。

### Windows Release 构建

`flutter build windows --release --no-pub`：**成功，退出码 0**，约 65.8 秒。最新程序为 **`build/windows/x64/runner/Release/kazumi.exe`**，同目录的 `data/app.so` 已更新。运行时保留整个 Release 目录的 DLL 和 `data`。日志：`.dart_tool/local_video_library_validation/build_release.log`。

构建仍有原有 NuGet 未安装提示和 `webview_windows` CMP0175 开发警告，未阻止生成程序。没有创建安装包；弹幕联网仍沿用下方现有凭据配置及验证边界。

## 以下为既有功能的历史验证记录

日期：2026-10-23。基线为 Kazumi 2.4.1，提交 `db5202611902fe67c449e0a53bc05c3a75b4e8b0`；修改位于当前工作目录的 `feature/windows-local-video` 分支。验证使用 Flutter 3.47.7、Dart 3.13.5。

## 本地字幕功能（2026-10-23）

Windows 本地视频的 **更多选项 → 字幕** 已接入内嵌软字幕、SRT/ASS/SSA/VTT 外挂、逐视频选择与开关恢复。通过 media-kit/mpv 的 libass 渲染；关闭同名字幕扫描和第二字幕轨道。没有新增运行时依赖。

### 自动测试与静态检查

- 先补设置模型、仓储及控制器测试，再实现对应接口；另补充“切回默认失败时重建原外挂”和“替换失败清理残留轨道”两项回归，先复现失败后修复通过。
- 完整 `flutter test --no-pub --reporter expanded`：**310 项通过、1 项因现有 Windows 文件链接权限限制跳过**，退出码 0。日志：`.dart_tool/subtitle_validation/unit_tests.log`。
- 新增及扩展测试覆盖旧记录兼容、Hive 重开后的逐视频隔离、开关保留选择、外挂更换与移除、损坏或失效文件、内嵌轨道缺失、轨道延迟就绪、快速切集和迟到的文件选择、保存失败，以及接口返回成功但实际没有轨道。其中字幕控制器 15 项、面板 14 项。
- 面板测试验证内嵌轨道的标题/语言/格式、当前单选状态、外挂操作、取消选择、忙碌时禁用、切集后失效与关闭边界；在 1280×720 和 640×360 弹层尺寸下可滚动且无溢出。
- `dart analyze`：退出码 0，无 error、warning，只有原有的 **17 项 info**。日志：`.dart_tool/subtitle_validation/analyze.log`。
- 核心实现经过只读规格及代码复审，确认恢复和切换使用会话/版本检查、仓储读取最新记录；默认选择检查原生 `options/sid`，外挂加载/移除检查实际轨道。播放器原有截图默认不含原生字幕的行为保留。

### Windows Release 编译

- 后续按用户要求重新编译，默认目录已无进程占用：`flutter build windows --release --no-pub` **成功，退出码 0**，用时约 18.6 秒。**最新程序位于 `build/windows/x64/runner/Release/kazumi.exe`**，已更新默认目录中的程序及 `data/app.so`。本次日志：`.dart_tool/subtitle_validation/build_release_default.log`。以下独立目录构建记录为此前结果。
- `flutter build windows --release --no-pub`：**编译成功，退出码 0**，独立目录构建用时约 242 秒。日志：`.dart_tool/subtitle_validation/build_release.log`。
- 默认目录的旧 `kazumi.exe` 正由现有播放器进程使用，首次构建在链接时遇到 `LNK1104`。保留该进程，改用独立输出目录，交付程序为 **`build/subtitle_release/windows/x64/runner/Release/kazumi.exe`**；运行时保留整个 Release 目录的 DLL 和 `data`。默认目录中的旧 exe 没有更新。
- 临时 Flutter 构建目录设置已清除并核对恢复默认值。最终产物中的 `libmpv-2.dll` 与下述实播使用的库 SHA-256 相同：`361e3a306707454a24e7d3558b2eb7a9ccc23a4f5ed396fe7e77f0a44908eda5`。
- 构建仍有 NuGet 检查/自动下载提示和原有 `webview_windows` CMP0175 开发警告，未阻止生成 Release。未创建安装包、提交或推送。

### Windows 原生渲染

运行 `flutter test --no-pub scripts/verify_subtitles.dart --reporter expanded`：**32 项断言通过**，退出码 0。脚本使用当前字幕控制器、media-kit 与 Release 目录中的 Windows `libmpv-2.dll`（mpv v0.41.0-1049），通过 GPU 输出实际渲染。

- 自制 12 秒、640×360 的 MKV 包含中文 ASS 与英文 SRT 双内嵌轨道；在打开媒体之前绑定控制器，实际读取标题、语言和格式后恢复选择。
- 四种外挂格式均加载成功并在原生轨道列表中实际选中；中文、空格和 `#` 文件名通过。逐次替换后只保留一个外挂轨道。
- 原生截图像素检查和视觉复核确认中文、ASS 的黄色/绿色、紫色描边及定位、SSA 紫色样式、VTT 文字正常。截图：`02_embedded_ass.png`、`04_external_ssa.png`、`04_external_vtt.png`。
- 损坏 SRT 被真实 mpv 拒绝时，旧选择与保存设置保持；报告中的唯一原生错误来自这项预期失败。
- 暂停、拖动、1.5 倍速、字幕开关和移除外挂通过；写入 JSON、销毁并重建播放器后，外挂、内嵌及关闭状态分别恢复。默认字幕实测 `sid=1`、`options/sid=auto`。

生成素材、截图及机器可读结果保存在 `.dart_tool/subtitle_validation/`，总结果见 `report.json`。脚本只访问自制素材和独立 JSON，不读取用户媒体或应用历史；ffmpeg 仅用于生成验证素材。

以上分别证明自动逻辑/控件布局与原生渲染，未进行完整应用的人工文件选择、全屏按钮操作或关闭 exe 后重启验收。Hive 重开、播放器重建及两种弹层尺寸已由对应测试覆盖，不能替代这些人工操作结果。后续章节保留此前本地视频功能的历史验证记录。

## 本地页面窗口关闭按钮修复

本地页面此前使用普通 `AppBar`，没有其他页面的窗口关闭入口。现改为项目已有的 `SysAppBar`，沿用原有窗口按钮设置、关闭操作和标题栏拖动行为。

- 新增 360 和 1280 宽度的窗口关闭回归测试；修复前均因按钮缺失失败，修复后显示按钮，点击通过模拟通道调用原有 `window_manager.close`。本地页面全部 8 项测试通过。
- 完整 `flutter test --no-pub`：**273 项通过、1 项因链接权限跳过**，退出码 0。
- `dart analyze`：退出码 0，无 error、warning，仍有 17 项原有 info。
- 独立验证脚本：**59 项通过、1 项跳过**。本地页面现依赖标准标题栏及完整应用设置，因此页面测试改由根目录完整测试执行，独立脚本只运行数据与纯逻辑测试。

本轮未重新构建 Release 程序，也未进行真实窗口点击验收。现有 exe 需要重新编译才能包含界面及此前弹幕凭据提示修复。

## 弹幕运行反馈与构建配置纠正

用户已确认 Release 程序可以播放本地视频，同时反馈本地和在线播放均不能加载或搜索弹幕。实际应用日志显示弹弹play的搜索及自动匹配请求均返回 HTTP 403。排查发现公开源码通过 `String.fromEnvironment` 读取 `DANDANAPI_APPID` / `DANDANAPI_KEY`，官方发布工作流从 GitHub Secrets 注入；此前本机编译命令没有注入这些参数。该构建没有有效弹幕 API 凭据，不能将测试通过或编译通过视为弹幕联网功能已恢复。

已补充无密钥的配置示例、忽略本机凭据文件的规则和 `scripts/build_windows.ps1`。客户端缺少任一凭据时在发送请求前返回明确的配置错误，弹幕搜索和选择面板展示该错误。配置与申请方式见 [使用说明](WINDOWS_LOCAL_VIDEO.md#弹幕-api-凭据自行编译必需)。

本轮验证：新增 3 项回归用例先失败、修复后通过；完整 `flutter test --no-pub` **271 项通过、1 项跳过**，`dart analyze` 退出码 0（无 error、warning，仍有 17 项原有 info）。构建脚本的 PowerShell 语法检查通过，且已验证空配置和缺少密钥的配置都会在调用 Flutter 前被拒绝；本机凭据文件忽略规则检查通过。

用户目前没有 API 凭据；真实的搜索、选集、获取弹幕仍需申请有效凭据后重新编译验收。

## 后续编译修复与最新结果

同日后续检查已识别完整的 VS Community 2022 17.14.33 和 Windows SDK 10.0.26100.0。此前工具链及 SDK 下载的阻断已解决。

随后复现 `ech_http 0.2.3` 内置 CA 证书生成一个超长原始字符串，触发 MSVC `C2026`。本地固定版本补丁只将生成的证书数据改为字节数组；来源、许可证及修改范围保存在 `third_party/ech_http`。没有升级其他依赖，也没有修改 Pub 全局缓存或生成目录来绕过问题。

- `flutter pub get`：退出码 0，仅将 `ech_http 0.2.3` 改为本地补丁来源。
- `flutter test --no-pub`：**268 项通过、1 项因链接权限跳过**，退出码 0。此前未执行的 19 项播放器控制器及 8 项弹幕源弹窗测试已在完整套件中执行通过。模拟接口测试没有调用真实弹幕 API。
- `dart analyze`：退出码 0，无 error、warning，只有原有的 17 项 info。
- `flutter build windows --release --no-pub`：**编译成功，退出码 0**，用时约 231 秒，生成 `build/windows/x64/runner/Release/kazumi.exe`。日志仍有 NuGet 未安装提示和 `webview_windows` 的 CMP0175 开发警告；两者未阻止这次构建。
- MSVC 最小回归：原生成头文件可稳定复现 `C2026`；补丁生成的头文件编译成功。从编译程序导出的证书与原始 `cacert.pem` 的 SHA-256 均为 `796f1389bfea13c0ed78f663b765baaff54a508e5483786bd6ece73c5e3e3cbe`，字节完全一致。

下列“初次交付”内容保留早先实际结果；完整测试目前的结论以上方结果为准。真实视频、真实网络和界面操作仍需运行验收。

## 初次交付已通过的检查（历史记录）

- `dart run build_runner build`：退出码 0，已更新必要的 MobX 生成文件。生成器提示 SDK 语言版本高于其分析器支持版本；未升级正式依赖。
- `flutter analyze --no-pub --no-fatal-infos`：退出码 0，无 error、warning；保留原有代码中的 17 项 info。默认 `flutter analyze --no-pub` 会因这些 info 返回非零。
- `git diff --check`：通过。
- 数据层、页面及播放器接入已完成规格与代码复审；最后发现的“切集后弹幕面板持续切换中”问题已修复并通过复审。

执行可复现脚本：

```powershell
.\scripts\test_local_video_units.ps1 -FlutterSdk '.\.tools\flutter'
```

结果为 **65 项通过、1 项跳过**。其中 28 项通过的用例覆盖本地视频数据、导入、页面、导航及弹幕请求生命周期，37 项通过的用例覆盖项目原有纯逻辑。跳过项需要当前 Windows 未提供的文件链接创建权限；目录访问失败另有模拟测试覆盖。

具体覆盖：

- 多文件导入、一次性递归扫描、扩展名、取消选择、重复路径、中文及特殊字符路径、无法访问的文件与目录、移除记录保留原文件。
- 真实 Hive 关闭后重新打开，恢复列表、进度与逐视频弹幕关联；两个视频的关联独立。
- 同一直接父目录的自然排序、缺失文件保留记录、列表的进度及关联展示、清除关联、Windows 与其他平台导航顺序。
- 使用模拟接口验证空弹幕、接口失败、重试、取消、快速切换及迟到结果失效。

脚本通过独立依赖工程引用同一份实际源码和测试，没有修改正式依赖或播放器。它不包含完整播放器控制器、弹幕源弹窗、原生解码或完整应用回归。

## 初次交付的环境阻断（历史记录）

| 检查 | 实际结果及边界 |
| --- | --- |
| `flutter pub get` | 已解析并获取依赖；随后因插件所需符号链接权限不足返回非零。正式 `pubspec.yaml` 和锁文件未修改。 |
| `flutter test --no-pub` | 在测试体执行前被既有 `ech_http 0.2.3` 原生构建钩子阻断：`Bad state: Install Visual Studio C++ build tools`。完整套件未通过。 |
| `flutter build windows --debug --no-pub` | 两次均在 Flutter Windows SDK 构建资源下载阶段遇到 ZIP 文件占用（OS Error 32），当时尚未进入应用编译，也缺少完整的 Visual Studio C++ 工具链。 |

另已编写并通过目标静态分析的 **19 项播放器控制器测试**和 **8 项弹幕源弹窗测试**，分别位于 `test/local_video_playback_test.dart` 与 `test/danmaku_source_session_test.dart`。它们随完整工程运行，同样受原生依赖阻断，**测试体未执行，不能计入通过数量**。

这些待执行用例覆盖续播设置、隐私进度、上一集/下一集边界、缺失文件后继续播放、文件 URI、退出与快速切集的会话失效，以及搜索选集、空弹幕、失败不覆盖关联、失效面板关闭和可重试状态。自动连播的实际播放器行为仍需下列运行验收。

## Windows 运行验收清单

编译成功后，仍需使用真实视频及网络完成：

- [ ] 多选与文件夹导入、缺失文件提示、移除不删除文件；退出重开后列表、进度、关联恢复。
- [ ] 不同容器和编码的视频可播放；中文、空格、`#` 等路径正常。
- [ ] 暂停、拖动、音量、倍速、快捷键、全屏及系统媒体标题正常。
- [ ] 同目录自然顺序、上一集/下一集边界；自动连播开启和关闭分别验证。
- [ ] 续播开关及隐私模式分别验证；退出和切集进度保存正常。
- [ ] 搜索番剧、选分集、重新关联、清除关联；空弹幕及接口失败不影响视频播放。
- [ ] 快速 A → B → A、弹幕面板打开时自动切集及退出播放，旧结果不应用到新会话。
- [ ] 暂停、拖动、倍速和时间偏移时弹幕同步正常。
- [ ] 在线播放、下载后播放、原有弹幕切换及其他平台导航的运行回归。

本次交付包括源码、测试和使用说明，并已验证 Windows Release 编译成功。真实视频、真实网络和界面操作的人工验收尚未进行；未制作安装包或便携包，也未发布到远程仓库。
