#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$OutputDirectory,
    [string]$ZipPath,
    [switch]$Force,
    [switch]$SkipPrepare
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:ToolRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path $script:ToolRoot 'dist\TrustedInstallerShell-portable'
}
if (-not $ZipPath) {
    $ZipPath = $OutputDirectory + '.zip'
}

function Remove-SafeDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }
    $fullPath = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $root = [IO.Path]::GetPathRoot($fullPath).TrimEnd('\')
    if ($fullPath -eq $root -or -not $fullPath) {
        throw '拒绝删除磁盘根目录。'
    }
    Remove-Item -LiteralPath $fullPath -Recurse -Force
}

$mainScript = Join-Path $script:ToolRoot 'scripts\Start-TrustedInstallerShell.ps1'
$moduleRoot = Join-Path $script:ToolRoot 'vendor\NtObjectManager\2.0.1'
$licensePath = Join-Path $script:ToolRoot 'licenses\Apache-2.0.txt'
if (-not (Test-Path -LiteralPath $mainScript -PathType Leaf)) {
    throw '缺少主脚本。'
}
if (-not (Test-Path -LiteralPath $licensePath -PathType Leaf)) {
    throw '缺少 licenses/Apache-2.0.txt。'
}

if (-not $SkipPrepare) {
    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $mainScript -Prepare -NoPause
    if ($LASTEXITCODE -ne 0) {
        throw '便携模块准备失败。'
    }
}
if (-not (Test-Path -LiteralPath (Join-Path $moduleRoot 'NtObjectManager.psd1') -PathType Leaf)) {
    throw '便携模块不存在。请移除 -SkipPrepare 后重试。'
}
if (-not $Force -and (Test-Path -LiteralPath $OutputDirectory)) {
    throw ('输出目录已存在：{0}。使用 -Force 覆盖。' -f $OutputDirectory)
}
if (-not $Force -and (Test-Path -LiteralPath $ZipPath)) {
    throw ('ZIP 已存在：{0}。使用 -Force 覆盖。' -f $ZipPath)
}

$stagingRoot = Join-Path ([IO.Path]::GetTempPath()) ('eco-ti-build-' + [guid]::NewGuid().ToString('N'))
$portableRoot = Join-Path $stagingRoot 'TrustedInstallerShell'
try {
    New-Item -ItemType Directory -Path (Join-Path $portableRoot 'scripts') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $portableRoot 'vendor\NtObjectManager') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $portableRoot 'licenses') -Force | Out-Null

    Copy-Item -LiteralPath (Join-Path $script:ToolRoot 'Start-TrustedInstallerShell.cmd') -Destination $portableRoot
    Copy-Item -LiteralPath (Join-Path $script:ToolRoot 'README.md') -Destination $portableRoot
    Copy-Item -LiteralPath (Join-Path $script:ToolRoot 'THIRD-PARTY-NOTICES.md') -Destination $portableRoot
    Copy-Item -LiteralPath $mainScript -Destination (Join-Path $portableRoot 'scripts')
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Build-Portable.ps1') -Destination (Join-Path $portableRoot 'scripts')
    Copy-Item -LiteralPath $moduleRoot -Destination (Join-Path $portableRoot 'vendor\NtObjectManager') -Recurse -Force
    Copy-Item -LiteralPath $licensePath -Destination (Join-Path $portableRoot 'licenses')

    $buildInfo = [ordered]@{
        name = 'TrustedInstallerShell'
        builtUtc = [DateTime]::UtcNow.ToString('o')
        module = 'NtObjectManager'
        moduleVersion = '2.0.1'
        modulePackageSha256 = 'E76F9A39760C12A36170516441987AD60F1699663CD5FB7C29705E68AB185BEB'
        portable = $true
    }
    $buildInfo | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $portableRoot 'build-info.json') -Encoding UTF8

    if (Test-Path -LiteralPath $OutputDirectory) {
        if (-not $Force) {
            throw ('输出目录已存在：{0}。使用 -Force 覆盖。' -f $OutputDirectory)
        }
        Remove-SafeDirectory -Path $OutputDirectory
    }
    $outputParent = Split-Path -Parent $OutputDirectory
    if ($outputParent) {
        New-Item -ItemType Directory -Path $outputParent -Force | Out-Null
    }
    Move-Item -LiteralPath $portableRoot -Destination $OutputDirectory

    if (Test-Path -LiteralPath $ZipPath) {
        if (-not $Force) {
            throw ('ZIP 已存在：{0}。使用 -Force 覆盖。' -f $ZipPath)
        }
        Remove-Item -LiteralPath $ZipPath -Force
    }
    Compress-Archive -LiteralPath $OutputDirectory -DestinationPath $ZipPath -CompressionLevel Optimal
    Write-Host ('便携目录：{0}' -f $OutputDirectory) -ForegroundColor Green
    Write-Host ('便携 ZIP：{0}' -f $ZipPath) -ForegroundColor Green
}
finally {
    $resolvedTemp = [IO.Path]::GetFullPath($stagingRoot)
    $allowedTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if ($resolvedTemp.StartsWith($allowedTemp, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $stagingRoot)) {
        Remove-Item -LiteralPath $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
