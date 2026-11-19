# TrustedInstaller Shell 便携工具

这是一个面向 Windows 10/11 x64 本机维护场景的便携 PowerShell 工具。它通过 `NtObjectManager` 取得 `TrustedInstaller.exe` 的进程令牌，并打开一个具有 TrustedInstaller 权限的受控 `cmd.exe`。它不修改文件所有者，也不修改目标文件 ACL。

发布提供两种等价形式：

- `TrustedInstallerShell-v<版本>-portable.zip`：完整目录版，解压后运行。
- `TrustedInstallerShell-v<版本>.exe`：单文件版，首次运行时把内置载荷解压到 `%LOCALAPPDATA%\EcoTools\TrustedInstallerShell\<版本>`。

## 便携性

- 所有依赖放在工具目录的 `vendor/`，不安装到系统 PowerShell 模块目录。
- `PSModulePath` 只在当前 PowerShell 进程中临时追加工具目录。
- 启动器只对当前 PowerShell 进程使用 `-ExecutionPolicy Bypass`，不调用 `Set-ExecutionPolicy`。
- 不写注册表、不写 PATH、不安装 NuGet Provider、不修改服务启动类型。
- 日志默认写入工具目录的 `logs/`，删除整个工具目录即可清理。
- 发布包包含固定版本的 `NtObjectManager 2.0.1` 和 Apache License 2.0，断网也可运行。

## 快速使用

目录版双击 `Start-TrustedInstallerShell.cmd`，单文件版直接双击 `TrustedInstallerShell-v<版本>.exe`。工具会先检查环境和便携模块，再请求管理员权限。实际打开命令窗口前还需要输入 `TRUSTEDINSTALLER` 确认。

常用模式：

```powershell
.\Start-TrustedInstallerShell.cmd -Status
.\Start-TrustedInstallerShell.cmd -SelfTest
.\Start-TrustedInstallerShell.cmd -Prepare
.\Start-TrustedInstallerShell.cmd -DryRun
.\Start-TrustedInstallerShell.cmd -VerifyToken -NoPause
.\Start-TrustedInstallerShell.cmd -Yes
```

参数说明：

- `-Prepare`：把固定版本模块准备到本工具目录。便携发布包已经包含模块，通常无需执行。
- `-Status`：只读显示系统、管理员状态、模块、服务和执行策略信息。
- `-SelfTest`：只读检查脚本、模块版本和所需命令是否可加载。
- `-DryRun`：以管理员身份检查环境，但不启动服务、不获取令牌。
- `-VerifyToken`：创建一个隐藏的 `whoami /groups` 子进程，验证是否取得 TrustedInstaller 组身份。
- `-NoWait`：打开命令窗口后立即返回。此时不自动恢复服务状态。
- `-KeepServiceRunning`：关闭命令窗口后不尝试停止本次启动的 TrustedInstaller 服务。
- `-Yes`：跳过实际打开命令窗口前的交互确认，适合受控自动化。
- `-ForceDownload`：重新下载并校验固定版本模块，只写入工具目录的 `vendor/`。

## 环境要求

- Windows 10 或 Windows 11，64 位进程。
- Windows PowerShell 5.1 或更高版本。
- 首次下载模块时需要能访问 PowerShell Gallery；便携发布包不需要网络。
- 实际获取令牌需要管理员权限和 UAC 确认。
- 如果企业策略禁用或阻止 `TrustedInstaller` 服务，工具会失败，不会修改服务启动配置。

## 安全边界

这个命令窗口拥有修改系统文件的权限。错误修改可能让 Windows 无法启动。不要从中运行 `explorer.exe`，不要把窗口留给不受信任的脚本，使用完成后立即关闭。

工具不会自动编辑系统文件。它只提供一个受控的交互式命令窗口，并记录启动、模块、服务状态和退出结果。

## 构建便携包

在工具目录运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Build-Portable.ps1
```

默认生成：

```text
dist/TrustedInstallerShell-portable/
dist/TrustedInstallerShell-portable.zip
```

构建脚本从 PowerShell Gallery 直接下载 NuGet 包，不依赖 NuGet Provider；下载后会校验固定 SHA-256，再展开到临时目录并复制模块文件。

## 构建单文件 EXE

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Build-SingleExe.ps1 -Version 1.0.0
```

单文件 EXE 把便携 ZIP 作为嵌入资源编译进去，不会在 EXE 旁边留下 DLL、PowerShell 脚本或模块目录。首次运行时只把载荷解压到当前用户的 `%LOCALAPPDATA%\EcoTools\TrustedInstallerShell\<版本>`，后续直接复用相同版本缓存。

## 构建两个 Release 资产

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Build-Release.ps1 -Version 1.0.0 -Force
```

输出：

```text
dist/release/TrustedInstallerShell-v1.0.0-portable.zip
dist/release/TrustedInstallerShell-v1.0.0.exe
dist/release/SHA256SUMS.txt
```

单文件 EXE 当前未做商业代码签名，Windows SmartScreen 可能显示未知发布者提示；文件哈希会随 Release 一同发布。

## 许可

本工具脚本使用仓库根目录的 MIT License。便携包内 `NtObjectManager` 使用 Apache License 2.0，详情见 `THIRD-PARTY-NOTICES.md` 与 `licenses/Apache-2.0.txt`。
