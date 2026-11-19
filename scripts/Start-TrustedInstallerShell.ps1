#requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$Prepare,
    [switch]$Launch,
    [switch]$Status,
    [switch]$SelfTest,
    [switch]$DryRun,
    [switch]$VerifyToken,
    [switch]$NoWait,
    [switch]$KeepServiceRunning,
    [switch]$ForceDownload,
    [switch]$NoPause,
    [switch]$Yes,
    [switch]$Elevated
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:RequiredModuleVersion = '2.0.1'
$script:ModulePackageUri = 'https://www.powershellgallery.com/api/v2/package/NtObjectManager/2.0.1'
$script:ModulePackageSha256 = 'E76F9A39760C12A36170516441987AD60F1699663CD5FB7C29705E68AB185BEB'
$script:ScriptPath = $MyInvocation.MyCommand.Path
$script:ToolRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$script:VendorRoot = Join-Path $script:ToolRoot 'vendor'
$script:ModuleRoot = Join-Path $script:VendorRoot ('NtObjectManager\' + $script:RequiredModuleVersion)
$script:ModuleManifest = Join-Path $script:ModuleRoot 'NtObjectManager.psd1'
$script:LogPath = $null
$script:FinalExitCode = 0
$script:SkipFinalPause = $false

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Initialize-Logging {
    $preferredRoot = Join-Path $script:ToolRoot 'logs'
    try {
        New-Item -ItemType Directory -Path $preferredRoot -Force | Out-Null
        $probe = Join-Path $preferredRoot ('.write-test-' + [guid]::NewGuid().ToString('N'))
        [IO.File]::WriteAllText($probe, '')
        Remove-Item -LiteralPath $probe -Force
        $script:LogPath = Join-Path $preferredRoot ('TrustedInstallerShell-' + (Get-Date -Format 'yyyyMMdd') + '.log')
    }
    catch {
        $fallbackRoot = Join-Path ([IO.Path]::GetTempPath()) 'EcoTrustedInstallerShell'
        New-Item -ItemType Directory -Path $fallbackRoot -Force | Out-Null
        $script:LogPath = Join-Path $fallbackRoot ('TrustedInstallerShell-' + (Get-Date -Format 'yyyyMMdd') + '.log')
    }
}

function Write-Log {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'OK')][string]$Level = 'INFO'
    )

    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Level, $Message
    try {
        Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8
    }
    catch {
        # 日志失败不阻断主流程。
    }

    $color = 'Gray'
    switch ($Level) {
        'WARN' { $color = 'Yellow' }
        'ERROR' { $color = 'Red' }
        'OK' { $color = 'Green' }
    }
    Write-Host ('[{0}] {1}' -f $Level, $Message) -ForegroundColor $color
}

function Get-SelectedMode {
    $modes = New-Object System.Collections.ArrayList
    if ($Prepare) { [void]$modes.Add('Prepare') }
    if ($Launch) { [void]$modes.Add('Launch') }
    if ($Status) { [void]$modes.Add('Status') }
    if ($SelfTest) { [void]$modes.Add('SelfTest') }
    if ($DryRun) { [void]$modes.Add('DryRun') }
    if ($VerifyToken) { [void]$modes.Add('VerifyToken') }

    if ($modes.Count -eq 0) {
        return 'Launch'
    }
    if ($modes.Count -gt 1) {
        throw '一次只能选择一个模式：-Prepare、-Launch、-Status、-SelfTest、-DryRun 或 -VerifyToken。'
    }
    return [string]$modes[0]
}

function Assert-SupportedHost {
    if ([Environment]::OSVersion.Version.Major -lt 10) {
        throw '仅支持 Windows 10 或 Windows 11。'
    }
    if (-not [Environment]::Is64BitOperatingSystem) {
        throw '仅支持 64 位 Windows。'
    }
    if (-not [Environment]::Is64BitProcess) {
        throw '请使用 64 位 Windows PowerShell。当前进程是 32 位。'
    }
    if ($PSVersionTable.PSVersion -lt [version]'5.1') {
        throw '需要 Windows PowerShell 5.1 或更高版本。'
    }
}

function Assert-Administrator {
    if (-not (Test-IsAdministrator)) {
        throw '此操作需要管理员权限。'
    }
}

function Assert-ToolRootWritable {
    try {
        $probe = Join-Path $script:ToolRoot ('.write-test-' + [guid]::NewGuid().ToString('N'))
        [IO.File]::WriteAllText($probe, '')
        Remove-Item -LiteralPath $probe -Force
    }
    catch {
        throw '工具目录不可写。请把整个便携目录复制到当前用户可写的位置后再运行。'
    }
}

function Get-InstalledModuleVersion {
    if (-not (Test-Path -LiteralPath $script:ModuleManifest -PathType Leaf)) {
        return $null
    }
    try {
        $manifestData = Import-PowerShellDataFile -LiteralPath $script:ModuleManifest
        return [string]$manifestData.ModuleVersion
    }
    catch {
        return $null
    }
}

function Install-LocalModule {
    param([switch]$Force)

    Assert-SupportedHost
    Assert-ToolRootWritable
    New-Item -ItemType Directory -Path $script:VendorRoot -Force | Out-Null

    if (-not $Force -and (Get-InstalledModuleVersion) -eq $script:RequiredModuleVersion) {
        Write-Log ('便携模块已就绪：NtObjectManager {0}' -f $script:RequiredModuleVersion) 'OK'
        return $script:ModuleManifest
    }

    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('eco-trustedinstaller-' + [guid]::NewGuid().ToString('N'))
    $stageRoot = Join-Path $script:VendorRoot ('NtObjectManager\.staging-' + [guid]::NewGuid().ToString('N'))
    try {
        New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
        $packagePath = Join-Path $tempRoot 'NtObjectManager.2.0.1.nupkg'
        $zipPath = Join-Path $tempRoot 'NtObjectManager.2.0.1.zip'
        $expandedRoot = Join-Path $tempRoot 'expanded'

        Write-Log '正在从 PowerShell Gallery 下载固定版本 NtObjectManager 2.0.1。'
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $script:ModulePackageUri -UseBasicParsing -OutFile $packagePath -TimeoutSec 180

        $actualHash = (Get-FileHash -LiteralPath $packagePath -Algorithm SHA256).Hash
        if ($actualHash -ne $script:ModulePackageSha256) {
            throw ('模块 SHA-256 校验失败。期望 {0}，实际 {1}。' -f $script:ModulePackageSha256, $actualHash)
        }
        Write-Log '模块 SHA-256 校验通过。' 'OK'

        Copy-Item -LiteralPath $packagePath -Destination $zipPath -Force
        Expand-Archive -LiteralPath $zipPath -DestinationPath $expandedRoot -Force

        New-Item -ItemType Directory -Path $stageRoot -Force | Out-Null
        $skipNames = @('package', '_rels', '[Content_Types].xml')
        foreach ($item in Get-ChildItem -LiteralPath $expandedRoot -Force) {
            if ($skipNames -contains $item.Name) {
                continue
            }
            Copy-Item -LiteralPath $item.FullName -Destination $stageRoot -Recurse -Force
        }

        foreach ($file in Get-ChildItem -LiteralPath $stageRoot -Recurse -File) {
            Unblock-File -LiteralPath $file.FullName -ErrorAction SilentlyContinue
        }

        $moduleVersion = Import-PowerShellDataFile -LiteralPath (Join-Path $stageRoot 'NtObjectManager.psd1')
        if ([string]$moduleVersion.ModuleVersion -ne $script:RequiredModuleVersion) {
            throw '下载的模块版本与固定版本不一致。'
        }

        if (Test-Path -LiteralPath $script:ModuleRoot) {
            $resolvedVendor = [IO.Path]::GetFullPath($script:VendorRoot).TrimEnd('\') + '\'
            $resolvedModule = [IO.Path]::GetFullPath($script:ModuleRoot)
            if (-not $resolvedModule.StartsWith($resolvedVendor, [StringComparison]::OrdinalIgnoreCase)) {
                throw '拒绝删除工具目录之外的模块路径。'
            }
            Remove-Item -LiteralPath $script:ModuleRoot -Recurse -Force
        }

        Move-Item -LiteralPath $stageRoot -Destination $script:ModuleRoot

        $hashLines = Get-ChildItem -LiteralPath $script:ModuleRoot -Recurse -File |
            Where-Object { $_.Name -ne '.manifest.sha256' } |
            Sort-Object FullName |
            ForEach-Object {
                $relative = $_.FullName.Substring($script:ModuleRoot.Length).TrimStart('\')
                $hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
                '{0}  {1}' -f $hash, $relative
            }
        Set-Content -LiteralPath (Join-Path $script:ModuleRoot '.manifest.sha256') -Value $hashLines -Encoding ASCII

        $sourceInfo = [ordered]@{
            id = 'NtObjectManager'
            version = $script:RequiredModuleVersion
            packageUri = $script:ModulePackageUri
            packageSha256 = $script:ModulePackageSha256
            installedUtc = [DateTime]::UtcNow.ToString('o')
        }
        $sourceInfo | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $script:ModuleRoot 'module-source.json') -Encoding UTF8

        Write-Log '便携模块已安装到工具目录。' 'OK'
        return $script:ModuleManifest
    }
    finally {
        $resolvedTemp = [IO.Path]::GetFullPath($tempRoot)
        $allowedTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        if ($resolvedTemp.StartsWith($allowedTemp, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $tempRoot)) {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $stageRoot) {
            Remove-Item -LiteralPath $stageRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Import-BundledModule {
    if (-not (Test-Path -LiteralPath $script:ModuleManifest -PathType Leaf)) {
        throw '便携模块不存在。请先运行 -Prepare，或使用包含 vendor/ 的便携发布包。'
    }

    $currentPath = [Environment]::GetEnvironmentVariable('PSModulePath', 'Process')
    if ($currentPath -notlike ($script:VendorRoot + '*')) {
        [Environment]::SetEnvironmentVariable('PSModulePath', $script:VendorRoot + ';' + $currentPath, 'Process')
    }

    Import-Module -Name $script:ModuleManifest -Force -ErrorAction Stop
    $loaded = Get-Module -Name NtObjectManager
    if ($null -eq $loaded -or [string]$loaded.Version -ne $script:RequiredModuleVersion) {
        throw 'NtObjectManager 加载失败或版本不匹配。'
    }

    $requiredCommands = @('Set-NtTokenPrivilege', 'Get-NtProcess', 'New-Win32Process')
    foreach ($commandName in $requiredCommands) {
        if ($null -eq (Get-Command -Name $commandName -ErrorAction SilentlyContinue)) {
            throw ('模块缺少必需命令：{0}' -f $commandName)
        }
    }
    return $loaded
}

function Ensure-ModuleReady {
    if ((Get-InstalledModuleVersion) -ne $script:RequiredModuleVersion) {
        Install-LocalModule | Out-Null
    }
    return Import-BundledModule
}

function Restart-Elevated {
    $singleQuote = [char]39
    $escapedScriptPath = $script:ScriptPath.Replace([string]$singleQuote, ([string]$singleQuote + $singleQuote))
    $arguments = @(
        ('& ' + $singleQuote + $escapedScriptPath + $singleQuote + ' -Elevated -NoPause')
    )
    if ($Prepare) { $arguments += '-Prepare' }
    if ($Launch) { $arguments += '-Launch' }
    if ($DryRun) { $arguments += '-DryRun' }
    if ($VerifyToken) { $arguments += '-VerifyToken' }
    if ($NoWait) { $arguments += '-NoWait' }
    if ($KeepServiceRunning) { $arguments += '-KeepServiceRunning' }
    if ($ForceDownload) { $arguments += '-ForceDownload' }
    if ($Yes) { $arguments += '-Yes' }

    $command = $arguments -join ' '
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $powershellPath = Join-Path $PSHOME 'powershell.exe'
    if (-not (Test-Path -LiteralPath $powershellPath -PathType Leaf)) {
        $powershellPath = 'powershell.exe'
    }

    Write-Log '正在请求管理员权限。'
    try {
        $process = Start-Process -FilePath $powershellPath -Verb RunAs -Wait -PassThru -ArgumentList @(
            '-NoLogo',
            '-NoProfile',
            '-ExecutionPolicy',
            'Bypass',
            '-EncodedCommand',
            $encoded
        )
        return [int]$process.ExitCode
    }
    catch {
        throw ('无法启动管理员实例，可能已取消 UAC。{0}' -f $_.Exception.Message)
    }
}

function Start-TrustedInstallerService {
    $service = Get-Service -Name TrustedInstaller -ErrorAction Stop
    $startedByTool = $false
    if ($service.Status -ne 'Running') {
        Write-Log 'TrustedInstaller 服务当前未运行，正在临时启动。'
        $startedByTool = $true
        try {
            Start-Service -Name TrustedInstaller -ErrorAction Stop
            $service.WaitForStatus('Running', [TimeSpan]::FromSeconds(20))
        }
        catch {
            Stop-Service -Name TrustedInstaller -ErrorAction SilentlyContinue
            throw
        }
    }
    else {
        Write-Log 'TrustedInstaller 服务已在运行，工具不会改变其原有状态。'
    }
    return [pscustomobject]@{
        StartedByTool = $startedByTool
    }
}

function Stop-TrustedInstallerServiceIfNeeded {
    param([bool]$StartedByTool)
    if (-not $StartedByTool -or $KeepServiceRunning) {
        return
    }
    try {
        $service = Get-Service -Name TrustedInstaller -ErrorAction Stop
        if ($service.Status -eq 'Running') {
            Stop-Service -Name TrustedInstaller -ErrorAction Stop
            Write-Log '已恢复 TrustedInstaller 服务到运行前的停止状态。'
        }
    }
    catch {
        Write-Log ('未能自动停止本次启动的 TrustedInstaller 服务：{0}' -f $_.Exception.Message) 'WARN'
    }
}

function Initialize-TrustedInstallerToken {
    Set-NtTokenPrivilege -Privilege SeDebugPrivilege -ErrorAction Stop | Out-Null
    $processes = @(Get-NtProcess -Name 'TrustedInstaller.exe' -ErrorAction Stop)
    if ($processes.Count -eq 0) {
        throw '找不到 TrustedInstaller.exe 进程。'
    }
    Write-Log ('已取得 TrustedInstaller.exe 进程对象，PID={0}。' -f $processes[0].ProcessId)
    return $processes[0]
}

function Get-CommandPromptPath {
    if ($env:ComSpec -and (Test-Path -LiteralPath $env:ComSpec -PathType Leaf)) {
        return $env:ComSpec
    }
    return (Join-Path $env:SystemRoot 'System32\cmd.exe')
}

function Invoke-TrustedInstallerCommandWindow {
    if (-not $Yes) {
        if (-not [Environment]::UserInteractive) {
            throw '当前会话无法交互确认。受控自动化可显式传入 -Yes。'
        }
        Write-Host ''
        Write-Host '警告：下一步会打开具有 TrustedInstaller 权限的命令窗口。' -ForegroundColor Yellow
        Write-Host '该窗口可以修改受保护的系统文件，错误操作可能导致 Windows 无法启动。' -ForegroundColor Yellow
        $answer = Read-Host '如确认继续，请输入 TRUSTEDINSTALLER'
        if ($answer -cne 'TRUSTEDINSTALLER') {
            throw '用户取消了权限窗口启动。'
        }
    }

    $serviceState = Start-TrustedInstallerService
    $openedInteractiveWindow = $false
    try {
        $trustedInstaller = Initialize-TrustedInstallerToken
        $cmdPath = Get-CommandPromptPath
        $quote = [char]34
        $commandLine = $quote + $cmdPath + $quote + ' /d /k ' + $quote + 'title TrustedInstaller Shell - eco portable & '
        $commandLine += 'echo WARNING: Protected Windows files can be modified here. & '
        $commandLine += 'echo Close this window when finished. & '
        $commandLine += 'echo. & whoami /groups /fo list' + $quote

        $arguments = @{
            CommandLine = $commandLine
            CreationFlags = 'NewConsole'
            ParentProcess = $trustedInstaller
            CurrentDirectory = $script:ToolRoot
            Title = 'TrustedInstaller Shell - eco portable'
        }
        if (-not $NoWait) {
            $arguments.Wait = $true
            $arguments.Close = $true
        }

        Write-Log '正在创建 TrustedInstaller 子进程。'
        New-Win32Process @arguments | Out-Null
        $openedInteractiveWindow = $true
        if ($NoWait) {
            Write-Log '已打开信任安装程序命令窗口，当前模式不会等待窗口关闭。' 'OK'
        }
        else {
            Write-Log 'TrustedInstaller 命令窗口已关闭。' 'OK'
        }
    }
    finally {
        if ($openedInteractiveWindow -and -not $NoWait) {
            Stop-TrustedInstallerServiceIfNeeded -StartedByTool $serviceState.StartedByTool
        }
        elseif ($serviceState.StartedByTool -and $NoWait) {
            Write-Log '由于使用了 -NoWait，本次启动的 TrustedInstaller 服务保持运行。' 'WARN'
        }
        else {
            Stop-TrustedInstallerServiceIfNeeded -StartedByTool $serviceState.StartedByTool
        }
    }
}

function Invoke-TokenVerification {
    $serviceState = Start-TrustedInstallerService
    $outputPath = Join-Path ([IO.Path]::GetTempPath()) ('eco-ti-whoami-' + [guid]::NewGuid().ToString('N') + '.txt')
    try {
        $trustedInstaller = Initialize-TrustedInstallerToken
        $cmdPath = Get-CommandPromptPath
        $quote = [char]34
        $commandLine = $quote + $cmdPath + $quote + ' /d /c whoami.exe /groups /fo csv > ' + $quote + $outputPath + $quote
        New-Win32Process -CommandLine $commandLine -CreationFlags NoWindow -ParentProcess $trustedInstaller -CurrentDirectory ([IO.Path]::GetTempPath()) -Wait -Close | Out-Null

        if (-not (Test-Path -LiteralPath $outputPath -PathType Leaf)) {
            throw '验证子进程没有生成 whoami 输出。'
        }
        $output = Get-Content -LiteralPath $outputPath -Raw -ErrorAction Stop
        if ($output -notmatch 'TrustedInstaller') {
            throw '验证失败：子进程令牌中未发现 TrustedInstaller 组。'
        }
        Write-Log '验证通过：子进程令牌包含 TrustedInstaller 组。' 'OK'
    }
    finally {
        if (Test-Path -LiteralPath $outputPath) {
            Remove-Item -LiteralPath $outputPath -Force -ErrorAction SilentlyContinue
        }
        Stop-TrustedInstallerServiceIfNeeded -StartedByTool $serviceState.StartedByTool
    }
}

function Invoke-SelfTest {
    Assert-SupportedHost
    Ensure-ModuleReady | Out-Null

    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($script:ScriptPath, [ref]$tokens, [ref]$parseErrors) | Out-Null
    if ($parseErrors.Count -gt 0) {
        throw ('PowerShell 语法检查失败：{0}' -f (($parseErrors | ForEach-Object { $_.Message }) -join '; '))
    }

    Write-Log 'PowerShell 语法检查通过。' 'OK'
    Write-Log ('环境检查：{0}，PowerShell {1}，管理员={2}。' -f [Environment]::OSVersion.VersionString, $PSVersionTable.PSVersion, (Test-IsAdministrator)) 'OK'
    Write-Log ('模块检查：NtObjectManager {0} 已从工具目录加载。' -f $script:RequiredModuleVersion) 'OK'
    Write-Log '自检完成。未启动服务，未创建 TrustedInstaller 子进程。' 'OK'
}

function Show-Status {
    $admin = Test-IsAdministrator
    $installedVersion = Get-InstalledModuleVersion
    $serviceText = '不可用'
    try {
        $service = Get-Service -Name TrustedInstaller -ErrorAction Stop
        $serviceText = [string]$service.Status
    }
    catch {
        $serviceText = '查询失败'
    }

    Write-Host ''
    Write-Host 'TrustedInstaller Shell 状态' -ForegroundColor Cyan
    Write-Host ('工具目录：{0}' -f $script:ToolRoot)
    Write-Host ('系统：{0}' -f [Environment]::OSVersion.VersionString)
    Write-Host ('PowerShell：{0}' -f $PSVersionTable.PSVersion)
    Write-Host ('64 位进程：{0}' -f [Environment]::Is64BitProcess)
    Write-Host ('管理员：{0}' -f $admin)
    if ($installedVersion) {
        Write-Host ('便携模块：NtObjectManager {0}' -f $installedVersion)
    }
    else {
        Write-Host '便携模块：未准备'
    }
    Write-Host ('TrustedInstaller 服务：{0}' -f $serviceText)
    Write-Host ('本进程执行策略：{0}' -f (Get-ExecutionPolicy -Scope Process))
    Write-Host ('日志：{0}' -f $script:LogPath)
    Write-Host ''
}

function Invoke-DryRun {
    Assert-Administrator
    Ensure-ModuleReady | Out-Null
    $service = Get-Service -Name TrustedInstaller -ErrorAction Stop
    Write-Log ('模拟检查通过：管理员权限、便携模块和 TrustedInstaller 服务均可用，当前服务状态={0}。' -f $service.Status) 'OK'
    Write-Log '模拟模式未启动服务、未获取令牌、未创建命令窗口。' 'OK'
}

Initialize-Logging
try {
    $mode = Get-SelectedMode
    Write-Log ('启动模式：{0}；工具目录={1}' -f $mode, $script:ToolRoot)

    switch ($mode) {
        'Status' {
            Show-Status
        }
        'Prepare' {
            Install-LocalModule -Force:$ForceDownload | Out-Null
            Import-BundledModule | Out-Null
            Write-Log '环境准备完成：模块固定在工具目录并可加载。' 'OK'
        }
        'SelfTest' {
            Invoke-SelfTest
        }
        default {
            Assert-SupportedHost
            if ((Get-InstalledModuleVersion) -ne $script:RequiredModuleVersion) {
                Install-LocalModule | Out-Null
            }

            if (-not (Test-IsAdministrator)) {
                if ($Elevated) {
                    throw '管理员实例仍未获得管理员权限。'
                }
                $script:FinalExitCode = Restart-Elevated
                $script:SkipFinalPause = $false
            }
            else {
                Assert-Administrator
                Import-BundledModule | Out-Null
                switch ($mode) {
                    'Launch' { Invoke-TrustedInstallerCommandWindow }
                    'DryRun' { Invoke-DryRun }
                    'VerifyToken' { Invoke-TokenVerification }
                    default { throw ('未知模式：{0}' -f $mode) }
                }
            }
        }
    }
}
catch {
    $script:FinalExitCode = 1
    Write-Log ($_.Exception.Message) 'ERROR'
    if ($_.ScriptStackTrace) {
        Add-Content -LiteralPath $script:LogPath -Value $_.ScriptStackTrace -Encoding UTF8 -ErrorAction SilentlyContinue
    }
}
finally {
    if (-not $NoPause -and -not $script:SkipFinalPause -and [Environment]::UserInteractive) {
        Write-Host ''
        Read-Host '按 Enter 关闭窗口' | Out-Null
    }
}

exit $script:FinalExitCode
