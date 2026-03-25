# macOS 打包说明

本文档说明如何在 macOS 上为当前仓库构建 Flutter 桌面版 RustDesk，并生成可分发的 `.app` / `.dmg`。

## 推荐入口

推荐使用仓库内脚本：

```bash
bash res/osx-dist.sh
```

这个脚本会额外处理以下事项：

- 检查 `python3`、`cargo`、`flutter`、`VCPKG_ROOT`
- 自动生成 `flutter_rust_bridge` 桥接代码
- 调用 `build.py` 执行 Flutter/macOS 构建
- 生成 `RustDesk.app`
- 本机安装了 `create-dmg` 时自动生成 `rustdesk-<version>.dmg`
- 未提供正式签名证书时，自动对 `.app` 做本地可运行的 ad-hoc 重签名
- 提供了签名和 notarization 参数时，自动执行签名和公证

## 依赖

至少需要准备：

- Xcode 和命令行工具
- Rust 工具链
- Python 3
- Flutter
- `vcpkg`
- `create-dmg`，用于生成 `.dmg`

建议安装：

```bash
brew install cmake create-dmg
```

如 `vcpkg` 在构建 `aom` 时提示缺少 `nasm`，先安装 `nasm`。

## Flutter 版本

当前仓库的 macOS Flutter 打包建议使用 `3.24.5`。过新的 Flutter 版本可能会导致依赖或主题 API 不兼容。

如果你本机已经有 Flutter 仓库，可以直接切一个 `3.24.5` worktree：

```bash
git -C "$HOME/develop/flutter" worktree add "$HOME/develop/flutter-3.24.5" 3.24.5
export FLUTTER_BIN="$HOME/develop/flutter-3.24.5/bin/flutter"
```

脚本会优先使用 `FLUTTER_BIN`。未设置时，默认使用 PATH 中的 `flutter`。

## vcpkg

确保已经设置：

```bash
export VCPKG_ROOT="$HOME/vcpkg"
```

首次在仓库根目录执行时，需要让 `vcpkg` 按当前工程的 manifest 安装依赖：

```bash
"$VCPKG_ROOT/vcpkg" install --x-install-root="$VCPKG_ROOT/installed"
```

## 首次初始化

如果仓库缺少子模块内容，先执行：

```bash
git submodule update --init --recursive
```

## 直接打包

在仓库根目录执行：

```bash
export VCPKG_ROOT="$HOME/vcpkg"
export FLUTTER_BIN="$HOME/develop/flutter-3.24.5/bin/flutter"
bash res/osx-dist.sh
```

默认行为：

- 运行 `python3 build.py --flutter --hwcodec --unix-file-copy-paste --screencapturekit`
- 输出 `.app`
- 若已安装 `create-dmg`，继续输出 `.dmg`

产物路径：

- `flutter/build/macos/Build/Products/Release/RustDesk.app`
- `rustdesk-<version>.dmg`

## 只构建 `.app`

如果只想得到 `.app`：

```bash
export VCPKG_ROOT="$HOME/vcpkg"
export FLUTTER_BIN="$HOME/develop/flutter-3.24.5/bin/flutter"
bash res/osx-dist.sh --app-only
```

## 签名与公证

提供签名证书后，脚本会对 `.app` 和 `.dmg` 使用正式签名：

```bash
export VCPKG_ROOT="$HOME/vcpkg"
export FLUTTER_BIN="$HOME/develop/flutter-3.24.5/bin/flutter"
export MACOS_CODESIGN_IDENTITY="Developer ID Application: Example"
bash res/osx-dist.sh
```

如果还要 notarize，额外提供 `rcodesign` 和 API key：

```bash
export RCODESIGN_API_KEY_PATH="$HOME/.p12/api-key.json"
```

当 `MACOS_CODESIGN_IDENTITY` 未设置时，脚本会自动执行 ad-hoc 重签名。这种签名适合本机直接运行，但不适合作为正式分发签名。

## 与 `build.py` 的关系

`build.py` 仍然是底层构建入口，`res/osx-dist.sh` 是面向 macOS 分发的包装脚本。

- 只想执行底层 Flutter 构建：`python3 build.py --flutter --hwcodec --unix-file-copy-paste --screencapturekit`
- 想稳定拿到可直接打开的 `.app` / `.dmg`：优先使用 `res/osx-dist.sh`

当前仓库已经修复了一个 macOS 打包问题：在 Flutter 构建完成后追加 `Contents/MacOS/service` 时，会重新对 `.app` 签名，避免出现 `dyld` 加载 `FlutterMacOS.framework` 失败的问题。

## 故障排查

### `Library not loaded: @rpath/FlutterMacOS.framework`

如果终端启动时报类似错误，通常是 `.app` 签名失效。可先执行：

```bash
codesign --force --deep --sign - "flutter/build/macos/Build/Products/Release/RustDesk.app"
```

然后重新打开应用。

### Flutter 版本过新导致编译失败

如果报错集中在 Flutter SDK API、主题类型或三方包兼容性上，优先切回 `Flutter 3.24.5` 再重试。

### `bridge_generated.rs` 或 `generated_bridge.dart` 缺失

不要手动维护这些文件，直接重新运行：

```bash
bash res/osx-dist.sh --app-only
```

脚本会自动刷新桥接代码。
