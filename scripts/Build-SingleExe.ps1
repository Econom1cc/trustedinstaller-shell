#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$Version = '1.0.0',
    [string]$PortableZip,
    [string]$OutputPath,
    [switch]$Force,
    [switch]$SkipSelfTest
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$toolRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if ($Version -notmatch '^\d+\.\d+\.\d+([-.][0-9A-Za-z.-]+)?$') {
    throw 'Version 必须是形如 1.0.0 或 1.0.0-beta.1 的版本号。'
}
if (-not $PortableZip) {
    $PortableZip = Join-Path $toolRoot 'dist\TrustedInstallerShell-portable.zip'
}
if (-not (Test-Path -LiteralPath $PortableZip -PathType Leaf)) {
    & (Join-Path $PSScriptRoot 'Build-Portable.ps1') -Force
    if ($LASTEXITCODE -ne 0) {
        throw '构建便携 ZIP 失败。'
    }
}
$PortableZip = (Resolve-Path -LiteralPath $PortableZip).Path

if (-not $OutputPath) {
    $OutputPath = Join-Path $toolRoot ('dist\release\TrustedInstallerShell-v{0}.exe' -f $Version)
}
$OutputPath = [IO.Path]::GetFullPath($OutputPath)
if ((Test-Path -LiteralPath $OutputPath) -and -not $Force) {
    throw ('输出 EXE 已存在：{0}。使用 -Force 覆盖。' -f $OutputPath)
}
$outputParent = Split-Path -Parent $OutputPath
New-Item -ItemType Directory -Path $outputParent -Force | Out-Null

$cscPath = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $cscPath -PathType Leaf)) {
    $cscPath = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe'
}
if (-not (Test-Path -LiteralPath $cscPath -PathType Leaf)) {
    throw '找不到 .NET Framework C# 编译器 csc.exe。'
}

$compressionAssembly = Get-ChildItem -LiteralPath (Join-Path $env:WINDIR 'Microsoft.NET\assembly\GAC_MSIL\System.IO.Compression') -Recurse -Filter 'System.IO.Compression.dll' | Select-Object -First 1
$compressionFileSystemAssembly = Get-ChildItem -LiteralPath (Join-Path $env:WINDIR 'Microsoft.NET\assembly\GAC_MSIL\System.IO.Compression.FileSystem') -Recurse -Filter 'System.IO.Compression.FileSystem.dll' | Select-Object -First 1
if (-not $compressionAssembly -or -not $compressionFileSystemAssembly) {
    throw '找不到 System.IO.Compression 运行时程序集。'
}

$programTemplatePath = Join-Path $toolRoot 'exe\Program.cs'
$programTemplate = [IO.File]::ReadAllText($programTemplatePath, (New-Object Text.UTF8Encoding($true)))
$payloadHash = (Get-FileHash -LiteralPath $PortableZip -Algorithm SHA256).Hash
$programSource = $programTemplate.Replace('__PAYLOAD_VERSION__', $Version).Replace('__PAYLOAD_SHA256__', $payloadHash)

$versionParts = (($Version -split '-')[0]).Split('.')
while ($versionParts.Count -lt 4) {
    $versionParts += '0'
}
$assemblyVersion = ($versionParts | Select-Object -First 4) -join '.'
$assemblySource = @"
using System.Reflection;
[assembly: AssemblyTitle("TrustedInstaller Shell")]
[assembly: AssemblyDescription("Portable TrustedInstaller command shell bootstrap")]
[assembly: AssemblyProduct("eco TrustedInstaller Shell")]
[assembly: AssemblyCompany("eco")]
[assembly: AssemblyCopyright("MIT License")]
[assembly: AssemblyVersion("$assemblyVersion")]
[assembly: AssemblyFileVersion("$assemblyVersion")]
[assembly: AssemblyInformationalVersion("$Version")]
"@

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('eco-ti-exe-' + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    $programPath = Join-Path $tempRoot 'Program.cs'
    $assemblyPath = Join-Path $tempRoot 'AssemblyInfo.cs'
    $utf8Bom = New-Object Text.UTF8Encoding($true)
    [IO.File]::WriteAllText($programPath, $programSource, $utf8Bom)
    [IO.File]::WriteAllText($assemblyPath, $assemblySource, $utf8Bom)

    if (Test-Path -LiteralPath $OutputPath) {
        Remove-Item -LiteralPath $OutputPath -Force
    }

    $compilerArguments = @(
        '/nologo',
        '/target:exe',
        '/platform:anycpu',
        '/optimize+',
        '/debug-',
        '/utf8output',
        ('/out:"{0}"' -f $OutputPath),
        ('/resource:"{0}",payload.zip,private' -f $PortableZip),
        '/r:System.Core.dll',
        ('/r:"{0}"' -f $compressionAssembly.FullName),
        ('/r:"{0}"' -f $compressionFileSystemAssembly.FullName),
        $programPath,
        $assemblyPath
    )
    & $cscPath @compilerArguments
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $OutputPath -PathType Leaf)) {
        throw '单文件 EXE 编译失败。'
    }
}
finally {
    $resolvedTemp = [IO.Path]::GetFullPath($tempRoot)
    $allowedTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if ($resolvedTemp.StartsWith($allowedTemp, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $tempRoot)) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$exe = Get-Item -LiteralPath $OutputPath
$exeHash = (Get-FileHash -LiteralPath $OutputPath -Algorithm SHA256).Hash
Write-Host ('单文件 EXE：{0}' -f $OutputPath) -ForegroundColor Green
Write-Host ('大小：{0:N2} MiB' -f ($exe.Length / 1MB))
Write-Host ('SHA-256：{0}' -f $exeHash)

if (-not $SkipSelfTest) {
    & $OutputPath -SelfTest -NoPause
    if ($LASTEXITCODE -ne 0) {
        throw '单文件 EXE 自检失败。'
    }
}
