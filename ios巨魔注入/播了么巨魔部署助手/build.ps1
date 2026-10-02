param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release'
)

$ErrorActionPreference = 'Stop'
$projectPath = Join-Path $PSScriptRoot 'Boleme.TrollDeploy.csproj'
$outputPath = Join-Path $PSScriptRoot '发布包-v0.2.0'
$toolPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'TrollRestore.exe'

if (-not (Test-Path -LiteralPath $toolPath)) {
    throw "缺少发布依赖：$toolPath"
}

dotnet publish $projectPath `
    --configuration $Configuration `
    --runtime win-x64 `
    --self-contained true `
    --output $outputPath `
    -p:PublishSingleFile=true `
    -p:IncludeNativeLibrariesForSelfExtract=true `
    -p:DebugType=None `
    -p:DebugSymbols=false

Write-Host "发布完成：$outputPath"
