# Windows 本地视频

基于 Kazumi **2.4.1**（`db5202611902fe67c449e0a53bc05c3a75b4e8b0`）。Windows x64 便携包通过 [本仓库 Releases](https://github.com/theStar7/Kazumi-Local/releases/latest) 提供，完整解压后运行 `kazumi.exe`，保留同目录的 DLL 和 `data`。自行编译方法见下文。

## 使用方法

1. Windows 导航选择 **本地**；窄窗口底部也有相同入口，位于“追番”和“我的”之间。
2. 点击 **导入视频** 多选文件，或 **导入文件夹** 递归建立目录入口。视频与文件夹显示为卡片。导入后软件层级可自由整理，进入文件夹和刷新只更新显示与文件状态；发现磁盘新增内容需再次导入文件夹。
3. 点击视频播放。播放列表仅包含进入播放时所在层的视频，按文件名自然排序，例如 `1.mp4 → 2.mp4 → 10.mp4`，不跨子文件夹。上一集、下一集与原有“自动播放下一集”设置继续有效，最后一项播完停止。
4. 播放时打开“更多选项 → 弹幕切换”，搜索番剧、选择番剧和分集。默认关键词为去掉扩展名的文件名，可以修改。每个视频独立保存所选分集，下次打开按保存的 ID 加载弹幕。
5. 重新打开“弹幕切换”可更换关联；“清除弹幕关联”可在播放器或本地列表的更多菜单中操作。加载失败仍可看视频，原关联会保留。

支持 MP4、MKV、AVI、MOV、WebM、FLV、WMV、M4V、TS、M2TS、MPG、MPEG，扩展名不区分大小写。实际解码能力沿用 media-kit；扩展名支持不等于每一种编码都已通过运行验证。

## 文件与数据

### 目录与分类

- **新建文件夹** 创建应用内文件夹，所有文件夹中都可以新建子文件夹、导入或 **添加已有视频**，包括从磁盘导入的文件夹。
- **长按约半秒拖动** 视频或文件夹卡片，放到文件夹卡片上即可移入。拖到面包屑中的上级，或拖动时出现的 **移到上级 / 移到媒体库** 区域即可移出；靠近网格上下边缘可自动滚动。松开在无效区域会取消。
- 点击卡片 **右下角三个点 → 移动到文件夹…**，逐层进入目标文件夹，点击 **移动到此处**。媒体库根层也是目标；当前位置、文件夹自身及其后代不能作为移动目标。
- 同一视频可通过“添加已有视频”保留在多个位置，共用进度、字幕和弹幕设置。从 A 移到 B 只取消 A 的引用，保留其他引用；从根层移入后根层卡片消失，移回根层后重新显示。
- 文件夹显示当前层视频和子文件夹数量，通过面包屑或返回按钮导航。导入后的名称与层级独立于磁盘路径；可以重命名或移动整个文件夹及其子树，不修改磁盘文件。
- 删除文件夹只移除应用内结构；移除最后一个引用或删除文件夹后，没有其他位置的视频会回到媒体库根层。根层的“从列表移除”则移除该视频的库记录及全部引用，源文件保留。
- 再次导入同一或重叠磁盘目录会复用已有记录、补充新内容，保留整理过的名称和位置，不把已移走的内容放回原处。
- 文件夹及根层成员保存在 `hive/localVideoFolders.hive`；旧目录关系首次进入页面时迁移为应用内引用。原 `localVideos.hive` 的进度、字幕与弹幕数据不重写。

### 视频封面

- 视频卡片从视频画面自动截取封面，按路径、文件大小和修改时间缓存。源文件变化后重新生成，缺失或解码失败时显示占位图。
- 封面生成使用现有 media-kit/mpv，静音且不创建播放窗口。串行处理，进入播放器前暂停并释放抽帧实例，返回列表后继续。
- 缓存位于应用临时目录的独立封面子目录；清理缓存不影响源视频、播放进度、字幕或弹幕设置。没有新增 ffmpeg 运行时依赖。

### 字幕

- 播放本地视频时，打开 **更多选项 → 字幕**。面板列出视频内嵌的软字幕，可按标题、语言和格式选择轨道；也可选择 **跟随视频默认字幕**。
- **添加外部字幕 / 替换文件** 可选择一个 SRT、ASS、SSA 或 VTT 文件，扩展名不区分大小写。只保存文件路径，不复制或修改字幕文件。
- 内嵌和外挂字幕使用 media-kit/mpv 的原生渲染，保留 ASS/SSA 的样式、位置与特效。字体使用系统或视频自带字体；未安装的专用字体可能使用替代字体。
- 同时显示一条字幕。字幕开关关闭后保留轨道和外挂路径；每个视频会记住所选来源、内嵌轨道和开关状态，下次播放时恢复。
- 切到内嵌字幕后仍保留一个外挂关联，可以再次选择。**移除关联** 不删除字幕文件；如果正在使用外挂，则恢复视频默认字幕。
- 新外挂加载失败会保留原字幕。保存过的外挂文件失效或内嵌轨道不存在时，本次回退到视频默认字幕，并保留原设置供重新选择。
- 字幕功能仅在 Windows 本地视频库提供；不扫描同名字幕，不包含字幕时间偏移或在线字幕搜索。

### 本地记录

- 只记录原始绝对路径，不复制视频。Windows 路径规范化后按大小写不敏感去重。
- 首次导入磁盘目录建立初始层级，扫描不跟随链接。此后仅主动导入扫描新内容，不在后台监听增删；源目录不可访问时仍可整理已有应用内文件夹。
- 文件夹内“从文件夹移除”只取消当前位置的引用，不删除磁盘文件。软件内移动同样只改变引用或文件夹父级。
- 文件移动或删除后记录会保留。可以恢复原路径下的文件，或重新导入新位置，再移除旧记录。
- 进度、弹幕关联与字幕设置保存在应用支持目录的 `hive/localVideos.hive`，不混入番剧历史或下载记录。新位置视为新视频，不自动迁移关联。隐私模式下字幕选择仍会保存，观看进度遵循原有隐私设置。
- 观看进度定时保存，并在切集和退出时保存；隐私模式下不更新进度。续播遵循现有续播设置。
- 本地播放保留暂停、拖动、倍速、音量、快捷键、全屏和弹幕设置，隐藏追番、在线评论、下载、投屏、一起看入口。
- 弹幕检索和加载需要网络。没有自动识别、分集推测、离线弹幕缓存或拖放导入。

## 弹幕 API 凭据（自行编译必需）

弹弹play要求应用通过 AppID 和 AppSecret 鉴权。官方 Kazumi 的发布流水线从仓库 Secrets 注入凭据，公开源码不包含这些值。自行执行不带参数的 `flutter build windows` 可以播放视频，但本地和在线播放的弹幕搜索、分集查询及下载都会因为缺少凭据而不可用。

1. 访问 [弹弹play开发者中心](https://dev.dandanplay.com)，注册账号、完善开发者资料并完成邮件验证。
2. 在“应用管理”创建自己的应用并提交审核；接入步骤见 [官方指南](https://doc.dandanplay.com/open/)。
3. 获得凭据后，在项目根目录复制配置示例：

   ```powershell
   Copy-Item .\config\dart_defines.example.json .\config\dart_defines.local.json
   notepad .\config\dart_defines.local.json
   ```

4. 将 AppID 填入 `DANDANAPI_APPID`，将一个有效 AppSecret 填入 `DANDANAPI_KEY`，保存文件。该本机文件已被 Git 忽略，不要将密钥提交到仓库或粘贴到聊天。
5. 编译：

   ```powershell
   .\scripts\build_windows.ps1 -DartDefineFile .\config\dart_defines.local.json
   ```

脚本会先验证两项都非空，再通过 `--dart-define-from-file` 注入编译参数，不把密钥值写进命令行。它优先使用项目内 `.tools/flutter`，否则使用 PATH 中的 Flutter。凭据属于编译配置，改完配置文件后必须重新编译程序。

若应用提示“未配置弹弹play API凭据”，需要完成上述配置；若配置后仍返回 401/403，应在开发者中心检查凭据是否有效，以及应用审核、API 权限或配额状态。没有有效凭据时不能验收真实弹幕接口。

## 开发与验证

项目要求 Flutter **3.47.7**。准备 Windows C++ 构建环境和插件所需符号链接权限后，在项目目录执行：

```powershell
# Git 依赖包含较长路径，仅在本进程启用 longpaths。
$env:GIT_CONFIG_COUNT = '1'
$env:GIT_CONFIG_KEY_0 = 'core.longpaths'
$env:GIT_CONFIG_VALUE_0 = 'true'
flutter pub get
dart run build_runner build
flutter analyze
flutter test
flutter build windows --debug --no-pub --dart-define-from-file=config/dart_defines.local.json
```

需要 Release 构建时，将最后一条改为 `flutter build windows --release --no-pub --dart-define-from-file=config/dart_defines.local.json`，或使用上面的构建脚本。成功后程序位于 `build/windows/x64/runner/Release/kazumi.exe`，运行时保留同目录的 DLL 和 `data`。

本源码包含 `third_party/ech_http`：它是固定版本 0.2.3 的本地构建补丁，用于修复 MSVC 编译内置 CA 证书时的 `C2026`（单个字符串过长）。只修改证书嵌入方式，证书内容和 TLS 校验不变，详细来源和差异见该目录的 `LOCAL_PATCH.md`。不要单独删除该目录或修改 Pub 全局缓存。

如果提示 `Building with plugins requires symlink support`，在 PowerShell 执行 `Start-Process 'ms-settings:developers'`，在设置中开启开发者模式后重试。

若完整测试被项目既有原生依赖构建阻断，可单独运行不需要这些原生依赖的数据与纯逻辑测试：

```powershell
.\scripts\test_local_video_units.ps1 -FlutterSdk 'C:\path\to\flutter'
```

脚本在 `.dart_tool/local_video_validation` 创建独立依赖工程，通过 Junction 引用**同一份实际源码和测试**，不修改正式依赖、不替换播放器或 SDK。此检查不包含页面、完整播放器控制器、原生解码或完整应用回归。本地页面复用系统标题栏，需要完整应用依赖；其测试在项目根目录执行 `flutter test test/local_video_page_test.dart`。

实际执行结果及待人工验收项目见 [验证记录](LOCAL_VIDEO_VERIFICATION.md)。

字幕原生验证使用自行生成的 12 秒 MKV，包含两条内嵌软字幕及四种外挂文件。先完成 Windows 构建，准备本机 ffmpeg，再运行：

```powershell
$env:SUBTITLE_FFMPEG = 'C:\path\to\ffmpeg.exe'
.\.tools\flutter\bin\flutter.bat test --no-pub scripts/verify_subtitles.dart --reporter expanded
```

脚本默认使用 Release 目录的 `libmpv-2.dll`，也可通过 `SUBTITLE_MPV_DLL` 指定。生成素材、原生截图和 `report.json` 写入已忽略的 `.dart_tool/subtitle_validation`；脚本不读取用户媒体或应用历史。ffmpeg 仅用于验证素材生成，不是新增运行时依赖。
