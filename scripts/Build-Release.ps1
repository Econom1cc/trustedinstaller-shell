#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$Version = '1.0.0',
    [string]$OutputDirectory,
    [switch]$Force
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$toolRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if ($Version -notmatch '^\d+\.\d+\.\d+([-.][0-9A-Za-z.-]+)?$') {
    throw 'Version 必须是形如 1.0.0 或 1.0.0-beta.1 的版本号。'
}
if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path $toolRoot 'dist\release'
}
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $OutputDirectory) {
    if (-not $Force) {
        throw ('输出目录已存在：{0}。使用 -Force 覆盖。' -f $OutputDirectory)
    }
    $fullPath = $OutputDirectory.TrimEnd('\')
    if ($fullPath -eq [IO.Path]::GetPathRoot($fullPath).TrimEnd('\')) {
        throw '拒绝删除磁盘根目录。'
    }
    Remove-Item -LiteralPath $OutputDirectory -Recurse -Force
}
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null

$stagingRoot = Join-Path $toolRoot ('dist\release-staging-' + [guid]::NewGuid().ToString('N'))
$portableDirectory = Join-Path $stagingRoot 'TrustedInstallerShell'
$portableZip = Join-Path $stagingRoot 'TrustedInstallerShell.zip'
try {
    & (Join-Path $PSScriptRoot 'Build-Portable.ps1') -Force -OutputDirectory $portableDirectory -ZipPath $portableZip
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $portableZip -PathType Leaf)) {
        throw '构建便携 ZIP 失败。'
    }

    $portableAsset = Join-Path $OutputDirectory ('TrustedInstallerShell-v{0}-portable.zip' -f $Version)
    $exeAsset = Join-Path $OutputDirectory ('TrustedInstallerShell-v{0}.exe' -f $Version)
    Copy-Item -LiteralPath $portableZip -Destination $portableAsset -Force

    & (Join-Path $PSScriptRoot 'Build-SingleExe.ps1') -Version $Version -PortableZip $portableZip -OutputPath $exeAsset -Force
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $exeAsset -PathType Leaf)) {
        throw '构建单文件 EXE 失败。'
    }

    $sumLines = @(
        ('{0}  {1}' -f (Get-FileHash -LiteralPath $portableAsset -Algorithm SHA256).Hash, (Split-Path -Leaf $portableAsset)),
        ('{0}  {1}' -f (Get-FileHash -LiteralPath $exeAsset -Algorithm SHA256).Hash, (Split-Path -Leaf $exeAsset))
    )
    Set-Content -LiteralPath (Join-Path $OutputDirectory 'SHA256SUMS.txt') -Value $sumLines -Encoding ASCII

    Write-Host ''
    Write-Host 'Release 资产已生成：' -ForegroundColor Green
    Get-ChildItem -LiteralPath $OutputDirectory -File | Select-Object Name, Length
}
finally {
    $resolvedStaging = [IO.Path]::GetFullPath($stagingRoot)
    $allowedRoot = [IO.Path]::GetFullPath((Join-Path $toolRoot 'dist')) + '\'
    if ($resolvedStaging.StartsWith($allowedRoot, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $stagingRoot)) {
        Remove-Item -LiteralPath $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
