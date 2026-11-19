#requires -Version 5.1
[CmdletBinding()]
param([switch]$IncludePrivileged)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$toolRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$mainScript = Join-Path $toolRoot 'scripts\Start-TrustedInstallerShell.ps1'
$allScripts = Get-ChildItem -LiteralPath (Join-Path $toolRoot 'scripts') -Filter '*.ps1' -File

foreach ($scriptFile in $allScripts) {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($scriptFile.FullName, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors.Count -gt 0) {
        throw ('语法错误：{0}：{1}' -f $scriptFile.Name, (($errors | ForEach-Object { $_.Message }) -join '; '))
    }
}

$unsafePolicyChange = Select-String -LiteralPath $allScripts.FullName -Pattern '^\s*Set-ExecutionPolicy\s+' -ErrorAction SilentlyContinue
if ($unsafePolicyChange) {
    throw '检测到永久执行策略修改调用。便携工具只允许进程级 -ExecutionPolicy Bypass。'
}

& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $mainScript -Status -NoPause
if ($LASTEXITCODE -ne 0) {
    throw '状态检查失败。'
}

& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $mainScript -SelfTest -NoPause
if ($LASTEXITCODE -ne 0) {
    throw '自检失败。'
}

if ($IncludePrivileged) {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    $isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        throw '运行 -IncludePrivileged 需要管理员 PowerShell。'
    }

    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $mainScript -DryRun -Elevated -NoPause
    if ($LASTEXITCODE -ne 0) {
        throw '管理员模拟运行失败。'
    }

    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $mainScript -VerifyToken -Elevated -NoPause
    if ($LASTEXITCODE -ne 0) {
        throw 'TrustedInstaller 令牌验证失败。'
    }
}

Write-Host 'TrustedInstaller Shell tests passed.' -ForegroundColor Green
