param([string]$FlutterSdk = '')
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
if ($FlutterSdk) {
    $flutterPath = Join-Path $FlutterSdk 'bin\flutter.bat'
} elseif (Test-Path (Join-Path $projectRoot '.tools\flutter\bin\flutter.bat')) {
    $flutterPath = Join-Path $projectRoot '.tools\flutter\bin\flutter.bat'
} else {
    $flutterPath = (Get-Command flutter -ErrorAction Stop).Source
}
$flutterPath = (Resolve-Path -LiteralPath $flutterPath).Path
$validationPath = Join-Path $projectRoot '.dart_tool\local_video_validation'
New-Item -ItemType Directory -Force -Path $validationPath | Out-Null
foreach ($name in @('lib', 'test')) {
    $target = Join-Path $projectRoot $name
    $link = Join-Path $validationPath $name
    if (Test-Path -LiteralPath $link) {
        $existing = Get-Item -LiteralPath $link
        if ($existing.LinkType -ne 'Junction' -or $existing.Target -ine $target) {
            throw "Existing path is not the expected source junction: $link"
        }
    } else {
        New-Item -ItemType Junction -Path $link -Target $target | Out-Null
    }
}
# Match the production lockfile's relevant versions; reference the actual source.
@'
name: kazumi
publish_to: none
environment:
  sdk: '>=3.10.0 <4.0.0'
dependencies:
  flutter:
    sdk: flutter
  hive_ce: 2.19.3
  path: 1.9.1
  crypto: 3.0.7
  file_picker: 10.3.10
dev_dependencies:
  flutter_test:
    sdk: flutter
  flutter_lints: ^6.0.0
'@ | Set-Content -LiteralPath (Join-Path $validationPath 'pubspec.yaml') -Encoding utf8
Push-Location $validationPath
try {
    & $flutterPath pub get
    if ($LASTEXITCODE -ne 0) { throw 'Validation dependency resolution failed.' }
    # Page tests use SysAppBar and full application dependencies; run them at the project root.
    & $flutterPath test --no-pub `
        test/local_video_model_test.dart `
        test/local_video_repository_test.dart `
        test/local_video_folder_repository_test.dart `
        test/local_video_navigation_test.dart `
        test/episode_danmaku_loader_test.dart `
        test/async_session_test.dart `
        test/async_single_flight_test.dart `
        test/async_rate_limiter_test.dart `
        test/episode_url_test.dart `
        test/m3u8_parser_test.dart `
        test/bangumi_image_url_rewriter_test.dart
    if ($LASTEXITCODE -ne 0) { throw 'Isolated unit tests failed.' }
} finally {
    Pop-Location
}
