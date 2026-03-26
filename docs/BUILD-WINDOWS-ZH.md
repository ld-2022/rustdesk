# Windows 打包说明

本文档说明如何在 Windows 上为当前仓库构建 Flutter 桌面版 RustDesk，并生成可分发的目录、`.exe` 以及可选的 `.msi`。

## 适用范围

- 宿主系统：Windows 10/11 x64
- 默认目标：Flutter 桌面版 `x86_64-pc-windows-msvc`
- 说明：当前仓库的 Windows Flutter 打包主路径是原生 Windows 构建，不建议从 macOS/Linux 直接交叉出完整 Windows 安装包

## 推荐入口

Windows 目前没有像 `res/osx-dist.sh` 那样的包装脚本，推荐直接使用仓库里的 `build.py`：

```powershell
python build.py --flutter --hwcodec --vram
```

默认行为：

- 构建 Rust 动态库和 Flutter Windows Runner
- 自动编译并拷贝 `dylib_virtual_display.dll`
- 生成 Flutter 产物目录
- 继续生成自解压安装包 `rustdesk-<version>-install.exe`

如果只想要 Flutter Runner 目录，不生成自解压安装包：

```powershell
python build.py --flutter --hwcodec --vram --skip-portable-pack
```

## 依赖

至少需要准备：

- Visual Studio 2022，勾选 “Desktop development with C++”
- Windows 10/11 SDK
- Rust 工具链
- Python 3
- Git
- Flutter
- LLVM/Clang
- `vcpkg`

如果还要构建 `.msi`，额外需要：

- `nuget`
- `MSBuild`
- 能正常构建 [res/msi/README.md](/Users/xianweizhang/Documents/zxw-work/rustdesk/res/msi/README.md) 中的安装器工程

## Flutter 版本

当前仓库的 Windows Flutter 打包建议使用 `3.24.5`，这与 CI 保持一致。过新的 Flutter 版本可能会引入主题 API 或 Windows engine 兼容问题。

如果你本机已经有 Flutter 仓库，可以直接切一个 `3.24.5` worktree：

```powershell
git -C C:\develop\flutter worktree add C:\develop\flutter-3.24.5 3.24.5
$env:Path = "C:\develop\flutter-3.24.5\bin;$env:Path"
flutter --version
```

## Flutter 补丁与 Windows 自定义 Engine

Windows CI 里会额外做两件事：

- 给 Flutter 打 `flutter_3.24.4_dropdown_menu_enableFilter.diff`
- 用 RustDesk 的 Windows engine 替换 Flutter 自带 engine

建议本地也跟 CI 保持一致。

先定位 Flutter 根目录：

```powershell
$flutterBin = (Get-Command flutter).Source
$flutterRoot = Split-Path (Split-Path $flutterBin -Parent) -Parent
```

应用补丁：

```powershell
Copy-Item .github\patches\flutter_3.24.4_dropdown_menu_enableFilter.diff $flutterRoot -Force
Push-Location $flutterRoot
git apply flutter_3.24.4_dropdown_menu_enableFilter.diff
Pop-Location
```

替换 Windows engine：

```powershell
flutter doctor -v
flutter precache --windows
Invoke-WebRequest `
  -Uri https://github.com/rustdesk/engine/releases/download/main/windows-x64-release.zip `
  -OutFile windows-x64-release.zip
Expand-Archive windows-x64-release.zip -DestinationPath windows-x64-release -Force
Copy-Item `
  .\windows-x64-release\* `
  "$flutterRoot\bin\cache\artifacts\engine\windows-x64-release\" `
  -Recurse -Force
```

## vcpkg

先准备并固定到 CI 使用的提交版本：

```powershell
git clone https://github.com/microsoft/vcpkg C:\vcpkg
cd C:\vcpkg
git checkout 120deac3062162151622ca4860575a33844ba10b
.\bootstrap-vcpkg.bat
```

设置环境变量：

```powershell
$env:VCPKG_ROOT = "C:\vcpkg"
```

首次在仓库根目录执行时，推荐按当前工程 manifest 安装依赖：

```powershell
& "$env:VCPKG_ROOT\vcpkg.exe" install `
  --triplet x64-windows-static `
  --x-install-root="$env:VCPKG_ROOT\installed"
```

## 首次初始化

如果仓库缺少子模块内容，先执行：

```powershell
git submodule update --init --recursive
```

## 直接打包

在仓库根目录执行：

```powershell
$env:VCPKG_ROOT = "C:\vcpkg"
$env:Path = "C:\develop\flutter-3.24.5\bin;$env:Path"
python build.py --flutter --hwcodec --vram
```

默认产物：

- `flutter\build\windows\x64\runner\Release\`
- `rustdesk-<version>-install.exe`

如果只想拿到未封装目录：

```powershell
$env:VCPKG_ROOT = "C:\vcpkg"
$env:Path = "C:\develop\flutter-3.24.5\bin;$env:Path"
python build.py --flutter --hwcodec --vram --skip-portable-pack
```

## 与 CI 对齐的 Windows 发布目录

仅运行 `build.py` 时，本地能得到可运行的 Flutter 产物和自解压安装包；但如果你想和 CI 一样组装完整 Windows 分发目录，还需要把一些额外文件补进去。

CI 当前会补这些内容：

- `usbmmidd_v2`
- 打印驱动目录 `RustDeskPrinterDriver`
- `printer_driver_adapter.dll`
- `RustDeskTempTopMostWindow` 的构建产物

对应逻辑可以参考 [.github/workflows/flutter-build.yml](/Users/xianweizhang/Documents/zxw-work/rustdesk/.github/workflows/flutter-build.yml#L169)。

典型目录整理方式：

```powershell
Remove-Item .\rustdesk -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path .\rustdesk | Out-Null
Copy-Item .\flutter\build\windows\x64\runner\Release\* .\rustdesk -Recurse -Force
```

然后再按需把驱动、打印组件和额外 DLL 放进 `.\rustdesk\`。

## 构建 MSI

如果已经准备好了 `.\rustdesk\` 目录，可以继续构建 MSI：

```powershell
Push-Location .\res\msi
python preprocess.py --arp -d ..\..\rustdesk
nuget restore msi.sln
msbuild msi.sln -p:Configuration=Release -p:Platform=x64 /p:TargetVersion=Windows10
Pop-Location
```

默认产物路径：

- `res\msi\Package\bin\x64\Release\en-us\Package.msi`

更多安装器细节见 [res/msi/README.md](/Users/xianweizhang/Documents/zxw-work/rustdesk/res/msi/README.md)。

## 与 `build.py` 的关系

`build.py` 是当前仓库 Windows Flutter 打包的底层入口。

- 只想执行 Flutter Windows 构建：`python build.py --flutter --hwcodec --vram --skip-portable-pack`
- 想顺手拿到自解压安装包：`python build.py --flutter --hwcodec --vram`
- 想做完整 Windows 发布目录或 MSI：在 `build.py` 产物基础上，继续补齐 CI 中的额外文件和安装器步骤

## 故障排查

### `cargo build` 失败，提示找不到 vcpkg 依赖

优先检查：

- `VCPKG_ROOT` 是否设置正确
- 是否执行过 `vcpkg install --triplet x64-windows-static --x-install-root=...`
- Visual Studio C++ 工具链和 Windows SDK 是否完整

### `flutter build windows` 失败

优先检查：

- Flutter 版本是否为 `3.24.5`
- 是否已经对 Flutter 打过仓库里的补丁
- 是否已经替换为 RustDesk 使用的 Windows engine

### 只生成了 Runner 目录，没有 `.exe`

你大概率传了 `--skip-portable-pack`。去掉这个参数后，`build.py` 会继续调用 `libs/portable/generate.py` 生成自解压安装包。

### `Package.msi` 构建失败

优先检查：

- `nuget restore msi.sln` 是否成功
- `msbuild` 是否来自 Visual Studio 2022
- `python preprocess.py --arp -d ..\..\rustdesk` 使用的目录是否已经准备完整
