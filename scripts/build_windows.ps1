param([Parameter(Mandatory = $true)][string]$DartDefineFile)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$definePath = (Resolve-Path -LiteralPath $DartDefineFile).Path
$defineConfig = Get-Content -LiteralPath $definePath -Raw | ConvertFrom-Json
foreach ($key in @('DANDANAPI_APPID', 'DANDANAPI_KEY')) {
    if ([string]::IsNullOrWhiteSpace([string]$defineConfig.$key)) {
        throw "Missing $key in the build configuration. Obtain credentials from https://dev.dandanplay.com before building with danmaku support."
    }
}
$bundledFlutter = Join-Path $projectRoot '.tools\flutter\bin\flutter.bat'
$flutterPath = if (Test-Path -LiteralPath $bundledFlutter) {
    $bundledFlutter
} else {
    (Get-Command flutter -ErrorAction Stop).Source
}
Push-Location $projectRoot
try {
    & $flutterPath pub get
    if ($LASTEXITCODE -ne 0) { throw 'Dependency resolution failed.' }
    & $flutterPath build windows --release --no-pub "--dart-define-from-file=$definePath"
    if ($LASTEXITCODE -ne 0) { throw 'Windows build failed.' }
} finally {
    Pop-Location
}
