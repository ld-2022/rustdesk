#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: res/osx-dist.sh [--app-only] [extra build.py args...]

Build RustDesk macOS Flutter artifacts from the repository root.

By default this script:
  1. Runs `python3 build.py --flutter --hwcodec --unix-file-copy-paste --screencapturekit`
  2. Produces `flutter/build/macos/Build/Products/Release/RustDesk.app`
  3. Produces `rustdesk-<version>.dmg` if `create-dmg` is installed

Environment:
  VCPKG_ROOT                Required. Path to your vcpkg checkout.
  FLUTTER_BIN               Optional. Path to a specific flutter executable.
  VERSION                   Optional. Overrides the version parsed from Cargo.toml.
  MACOS_CODESIGN_IDENTITY   Optional. If set, sign the app and dmg.
  RCODESIGN_API_KEY_PATH    Optional. If set and `rcodesign` is installed, notarize the dmg.
  DRY_RUN=1                 Print commands without executing them.

Examples:
  VCPKG_ROOT=$HOME/vcpkg bash res/osx-dist.sh
  VCPKG_ROOT=$HOME/vcpkg bash res/osx-dist.sh --app-only --skip-cargo
  VCPKG_ROOT=$HOME/vcpkg MACOS_CODESIGN_IDENTITY="Developer ID Application: Example" bash res/osx-dist.sh
EOF
}

log() {
  printf '[osx-dist] %s\n' "$*"
}

die() {
  printf '[osx-dist] %s\n' "$*" >&2
  exit 1
}

run() {
  printf '+'
  for arg in "$@"; do
    printf ' %q' "$arg"
  done
  printf '\n'
  if [[ "${DRY_RUN:-0}" != "1" ]]; then
    "$@"
  fi
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

ensure_cargo() {
  if command -v cargo >/dev/null 2>&1; then
    return
  fi
  if [[ -f "$HOME/.cargo/env" ]]; then
    # shellcheck disable=SC1090
    source "$HOME/.cargo/env"
  fi
  command -v cargo >/dev/null 2>&1 || die "cargo not found. Install Rust or source ~/.cargo/env first."
}

get_repo_version() {
  python3 - <<'PY'
from pathlib import Path
import re

text = Path("Cargo.toml").read_text(encoding="utf-8")
match = re.search(r'^version\s*=\s*"([^"]+)"', text, re.MULTILINE)
if not match:
    raise SystemExit("failed to read version from Cargo.toml")
print(match.group(1))
PY
}

get_flutter_version() {
  "${flutter_cmd}" --version 2>/dev/null | awk '/^Flutter / {print $2; exit}'
}

ensure_frb_codegen() {
  if command -v flutter_rust_bridge_codegen >/dev/null 2>&1; then
    return
  fi
  log "Installing flutter_rust_bridge_codegen 1.80.1"
  run cargo install flutter_rust_bridge_codegen --version 1.80.1 --features uuid --locked
}

generate_bridge_files() {
  ensure_frb_codegen
  log "Refreshing flutter_rust_bridge bindings"
  (
    cd flutter
    run "${flutter_cmd}" pub get
  )
  run env \
    RUST_LOG=info \
    flutter_rust_bridge_codegen \
    --rust-input ./src/flutter_ffi.rs \
    --dart-output ./flutter/lib/generated_bridge.dart \
    --rust-output ./src/bridge_generated.rs \
    --c-output ./flutter/macos/Runner/bridge_generated.h \
    --rust-crate-dir .
}

sign_app_bundle() {
  require_cmd codesign
  if [[ -n "${MACOS_CODESIGN_IDENTITY:-}" ]]; then
    log "Signing app bundle with identity: ${MACOS_CODESIGN_IDENTITY}"
    run codesign --force --deep --options runtime --strict -s "${MACOS_CODESIGN_IDENTITY}" "${app_path}" -vvv
  else
    log "MACOS_CODESIGN_IDENTITY is not set; applying ad-hoc signature so the app can launch locally."
    run codesign --force --deep --sign - "${app_path}"
  fi
}

app_only=0
build_py_args=()

while (($# > 0)); do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --app-only)
      app_only=1
      ;;
    --)
      shift
      while (($# > 0)); do
        build_py_args+=("$1")
        shift
      done
      break
      ;;
    *)
      build_py_args+=("$1")
      ;;
  esac
  shift
done

[[ "$(uname -s)" == "Darwin" ]] || die "This script is intended for macOS hosts only."

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
cd "${repo_root}"

require_cmd python3
ensure_cargo

flutter_cmd="${FLUTTER_BIN:-flutter}"
if [[ "${flutter_cmd}" == */* ]]; then
  [[ -x "${flutter_cmd}" ]] || die "Flutter executable not found: ${flutter_cmd}"
  export PATH="$(cd "$(dirname "${flutter_cmd}")" && pwd):${PATH}"
else
  require_cmd "${flutter_cmd}"
fi

[[ -n "${VCPKG_ROOT:-}" ]] || die "VCPKG_ROOT is not set."
[[ -d "${VCPKG_ROOT}" ]] || die "VCPKG_ROOT does not exist: ${VCPKG_ROOT}"

flutter_version="$(get_flutter_version || true)"
if [[ -n "${flutter_version}" && "${flutter_version}" != "3.24.5" ]]; then
  log "Flutter ${flutter_version} detected; CI is pinned to 3.24.5. Continuing anyway."
fi

version="${VERSION:-$(get_repo_version)}"
app_path="${repo_root}/flutter/build/macos/Build/Products/Release/RustDesk.app"
dmg_path="${repo_root}/rustdesk-${version}.dmg"

build_cmd=(
  python3
  build.py
  --flutter
  --hwcodec
  --unix-file-copy-paste
  --screencapturekit
)
if ((${#build_py_args[@]} > 0)); then
  build_cmd+=("${build_py_args[@]}")
fi

generate_bridge_files
run "${build_cmd[@]}"
[[ -d "${app_path}" ]] || die "Expected app bundle not found: ${app_path}"
sign_app_bundle
log "App ready: ${app_path}"

if [[ "${app_only}" == "1" ]]; then
  log "DMG packaging skipped (--app-only)."
  exit 0
fi

if ! command -v create-dmg >/dev/null 2>&1; then
  log "create-dmg not found; skipping DMG packaging. Install it with: brew install create-dmg"
  exit 0
fi

run rm -f "${dmg_path}"
run create-dmg \
  --icon "RustDesk.app" 200 190 \
  --hide-extension "RustDesk.app" \
  --window-size 800 400 \
  --app-drop-link 600 185 \
  "${dmg_path}" \
  "${app_path}"
log "DMG ready: ${dmg_path}"

if [[ -n "${MACOS_CODESIGN_IDENTITY:-}" ]]; then
  run codesign --force --options runtime --deep --strict -s "${MACOS_CODESIGN_IDENTITY}" "${dmg_path}" -vvv
fi

api_key_path="${RCODESIGN_API_KEY_PATH:-$HOME/.p12/api-key.json}"
if [[ -n "${MACOS_CODESIGN_IDENTITY:-}" ]]; then
  if [[ -f "${api_key_path}" ]]; then
    if command -v rcodesign >/dev/null 2>&1; then
      run rcodesign notary-submit --api-key-path "${api_key_path}" --staple "${dmg_path}"
      log "Notarized DMG: ${dmg_path}"
    else
      log "RCODESIGN_API_KEY_PATH is set but rcodesign is not installed; skipping notarization."
    fi
  else
    log "Notarization skipped; API key not found at ${api_key_path}"
  fi
elif [[ -n "${RCODESIGN_API_KEY_PATH:-}" ]]; then
  log "RCODESIGN_API_KEY_PATH is set but MACOS_CODESIGN_IDENTITY is not; skipping notarization."
fi
