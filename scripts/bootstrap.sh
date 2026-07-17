#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS_DIR="$ROOT_DIR/.tmp/toolchains"
BIN_DIR="$TOOLS_DIR/bin"
TARGET_OS="${TARGET_OS:-$(uname | tr '[:upper:]' '[:lower:]')}"
TARGET_ARCH="${TARGET_ARCH:-$(uname -m)}"
AUTO_INSTALL_XCODE="${AUTO_INSTALL_XCODE:-0}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch)
      TARGET_ARCH="$2"
      shift 2
      ;;
    --os)
      TARGET_OS="$2"
      shift 2
      ;;
    *)
      echo "Unknown bootstrap option: $1" >&2
      exit 1
      ;;
  esac
done

mkdir -p "$TOOLS_DIR" "$BIN_DIR"

download() {
  local url="$1"
  local target="$2"
  if [[ ! -f "$target" ]]; then
    echo "Downloading $url"
    curl -L --fail --retry 3 "$url" -o "$target"
  fi
}

normalize_go_arch() {
  case "$1" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    *) echo "$1" ;;
  esac
}

normalize_nfpm_asset_arch() {
  case "$1" in
    x86_64|amd64) echo "x86_64" ;;
    aarch64|arm64) echo "arm64" ;;
    *) echo "$1" ;;
  esac
}

normalize_java_arch() {
  case "$1" in
    x86_64|amd64) echo "x64" ;;
    aarch64|arm64) echo "aarch64" ;;
    *) echo "$1" ;;
  esac
}

normalize_java_os() {
  case "$1" in
    darwin) echo "mac" ;;
    *) echo "$1" ;;
  esac
}

normalize_python_arch() {
  local os_name="$1"
  local arch_name="$2"
  case "$os_name:$arch_name" in
    linux:x86_64|linux:amd64) echo "x86_64" ;;
    linux:aarch64|linux:arm64) echo "aarch64" ;;
    darwin:aarch64|darwin:arm64) echo "arm64" ;;
    darwin:x86_64|darwin:amd64) echo "x86_64" ;;
    *) echo "$arch_name" ;;
  esac
}

normalize_python_os() {
  case "$1" in
    linux) echo "Linux" ;;
    darwin) echo "MacOSX" ;;
    *) echo "" ;;
  esac
}

setup_homebrew_env() {
  local brew_bin="${1:-}"
  if [[ -z "$brew_bin" ]]; then
    if command -v brew >/dev/null 2>&1; then
      brew_bin="$(command -v brew)"
    elif [[ -x /opt/homebrew/bin/brew ]]; then
      brew_bin="/opt/homebrew/bin/brew"
    elif [[ -x /usr/local/bin/brew ]]; then
      brew_bin="/usr/local/bin/brew"
    fi
  fi

  if [[ -n "$brew_bin" ]]; then
    eval "$("$brew_bin" shellenv)"
  fi
}

ensure_homebrew() {
  if [[ "$TARGET_OS" != "darwin" ]]; then
    return
  fi

  setup_homebrew_env
  if command -v brew >/dev/null 2>&1; then
    return
  fi

  echo "Homebrew was not found. Installing it to prepare macOS desktop build dependencies."
  NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  setup_homebrew_env

  if ! command -v brew >/dev/null 2>&1; then
    echo "Homebrew installation completed, but 'brew' is still unavailable in PATH." >&2
    exit 1
  fi
}

ensure_cocoapods() {
  if [[ "$TARGET_OS" != "darwin" ]]; then
    return
  fi

  if command -v pod >/dev/null 2>&1; then
    return
  fi

  ensure_homebrew
  echo "Installing CocoaPods with Homebrew."
  brew install cocoapods

  if ! command -v pod >/dev/null 2>&1; then
    echo "CocoaPods installation completed, but 'pod' is still unavailable in PATH." >&2
    exit 1
  fi
}

attempt_xcode_install() {
  if [[ "$TARGET_OS" != "darwin" || "$AUTO_INSTALL_XCODE" != "1" ]]; then
    return 1
  fi

  if [[ ! -d /Applications/Xcode.app ]]; then
    echo "Full Xcode is missing. Attempting App Store installation."
    ensure_homebrew

    if ! command -v mas >/dev/null 2>&1; then
      echo "Installing the Mac App Store CLI with Homebrew."
      brew install mas
    fi

    if ! mas get 497799835; then
      cat >&2 <<'EOF'
The Mac App Store CLI could not get Xcode.

Open the App Store app, confirm you are signed in, then rerun:
  AUTO_INSTALL_XCODE=1 ./scripts/bootstrap.sh --os darwin --arch arm64
EOF
      exit 1
    fi
  fi

  if [[ ! -d /Applications/Xcode.app ]]; then
    cat >&2 <<'EOF'
Xcode installation did not produce /Applications/Xcode.app.

Install Xcode from the App Store manually, then rerun bootstrap.
EOF
    exit 1
  fi

  echo "Xcode.app is installed. Attempting developer-directory setup."
  if sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer \
      && sudo xcodebuild -license accept \
      && sudo xcodebuild -runFirstLaunch; then
    return 0
  fi

  cat >&2 <<'EOF'
Xcode was installed, but privileged first-launch setup still needs to run.

Complete these commands, then rerun bootstrap:
  sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
  sudo xcodebuild -license accept
  sudo xcodebuild -runFirstLaunch
EOF
  exit 1
}

ensure_macos_host_tools() {
  if [[ "$TARGET_OS" != "darwin" ]]; then
    return
  fi

  local developer_dir=""
  developer_dir="$(xcode-select -p 2>/dev/null || true)"
  if [[ -z "$developer_dir" || ! -d "$developer_dir" || "$developer_dir" == "/Library/Developer/CommandLineTools" ]]; then
    if ! attempt_xcode_install; then
      cat >&2 <<'EOF'
Full Xcode is required for macOS Flutter builds. The active developer directory is not a full Xcode install.

Install Xcode from the App Store, then run:
  sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
  sudo xcodebuild -license accept
  sudo xcodebuild -runFirstLaunch

To let bootstrap attempt the App Store install for you first, rerun with:
  AUTO_INSTALL_XCODE=1 ./scripts/bootstrap.sh --os darwin --arch arm64
EOF
      exit 1
    fi
    developer_dir="$(xcode-select -p 2>/dev/null || true)"
    if [[ -z "$developer_dir" || ! -d "$developer_dir" || "$developer_dir" == "/Library/Developer/CommandLineTools" ]]; then
      echo "Xcode setup completed, but the active developer directory is still not a full Xcode install." >&2
      exit 1
    fi
  fi

  if ! xcodebuild -version >/dev/null 2>&1; then
    if ! attempt_xcode_install; then
      cat >&2 <<'EOF'
Full Xcode is required for macOS Flutter builds, but 'xcodebuild' is not available from the active developer directory.

Verify that Xcode is installed, then run:
  sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
  sudo xcodebuild -license accept
  sudo xcodebuild -runFirstLaunch

To let bootstrap attempt the App Store install for you first, rerun with:
  AUTO_INSTALL_XCODE=1 ./scripts/bootstrap.sh --os darwin --arch arm64
EOF
      exit 1
    fi
    if ! xcodebuild -version >/dev/null 2>&1; then
      echo "Xcode setup completed, but 'xcodebuild' is still unavailable." >&2
      exit 1
    fi
  fi

  ensure_homebrew
  ensure_cocoapods
  if [[ ! -d "$HOME/.cocoapods/repos" ]]; then
    echo "Running one-time CocoaPods setup."
    pod setup --silent
  fi
}

ensure_flutter() {
  local dir="$TOOLS_DIR/flutter"
  if [[ ! -x "$dir/bin/flutter" ]]; then
    rm -rf "$dir"
    git clone https://github.com/flutter/flutter.git --depth 1 -b stable "$dir"
  fi

  if [[ "$TARGET_OS" == "darwin" ]]; then
    "$dir/bin/flutter" config --enable-macos-desktop
    "$dir/bin/flutter" precache --macos
  fi
}

ensure_python() {
  local python_dir="$TOOLS_DIR/python"
  if [[ -x "$python_dir/bin/python3" ]]; then
    return
  fi

  local python_os
  python_os="$(normalize_python_os "$TARGET_OS")"
  if [[ -z "$python_os" ]]; then
    return
  fi

  local python_arch
  python_arch="$(normalize_python_arch "$TARGET_OS" "$TARGET_ARCH")"
  local version="25.3.1-0"
  local installer="$TOOLS_DIR/miniforge-${TARGET_OS}-${python_arch}.sh"
  local url="https://github.com/conda-forge/miniforge/releases/download/${version}/Miniforge3-${python_os}-${python_arch}.sh"

  download "$url" "$installer"
  chmod +x "$installer"
  rm -rf "$python_dir"
  bash "$installer" -b -p "$python_dir"
}

ensure_go() {
  local go_arch
  go_arch="$(normalize_go_arch "$TARGET_ARCH")"
  local archive="$TOOLS_DIR/go-${TARGET_OS}-${go_arch}.tar.gz"
  if [[ ! -x "$TOOLS_DIR/go/bin/go" ]]; then
    local version
    version="$(curl -fsSL https://go.dev/VERSION?m=text | head -n 1)"
    download "https://go.dev/dl/${version}.${TARGET_OS}-${go_arch}.tar.gz" "$archive"
    rm -rf "$TOOLS_DIR/go"
    tar -C "$TOOLS_DIR" -xzf "$archive"
  fi
}

ensure_rust() {
  local rustup="$TOOLS_DIR/rustup-init"
  if [[ ! -x "$TOOLS_DIR/cargo/bin/cargo" ]]; then
    download "https://sh.rustup.rs" "$rustup"
    chmod +x "$rustup"
    CARGO_HOME="$TOOLS_DIR/cargo" RUSTUP_HOME="$TOOLS_DIR/rustup" "$rustup" -y --default-toolchain stable
  fi
}

ensure_java() {
  local java_arch
  java_arch="$(normalize_java_arch "$TARGET_ARCH")"
  local java_os
  java_os="$(normalize_java_os "$TARGET_OS")"
  local dir="$TOOLS_DIR/java"
  local archive="$TOOLS_DIR/java-${TARGET_OS}-${java_arch}.tar.gz"
  if [[ ! -x "$dir/bin/java" ]]; then
    local api="https://api.adoptium.net/v3/binary/latest/21/ga/${java_os}/${java_arch}/jdk/hotspot/normal/eclipse"
    download "$api" "$archive"
    rm -rf "$dir"
    mkdir -p "$dir"
    tar -C "$dir" --strip-components=1 -xzf "$archive"
    if [[ -d "$dir/Contents/Home" ]]; then
      local normalized_home="$TOOLS_DIR/java-home"
      rm -rf "$normalized_home"
      mv "$dir/Contents/Home" "$normalized_home"
      rm -rf "$dir"
      mv "$normalized_home" "$dir"
    fi
  fi
}

ensure_nFpm() {
  if [[ "$TARGET_OS" != "linux" ]]; then
    return
  fi
  local nfpm_arch
  nfpm_arch="$(normalize_nfpm_asset_arch "$TARGET_ARCH")"
  local nfpm_dir="$TOOLS_DIR/nfpm"
  local nfpm_bin="$nfpm_dir/nfpm"
  if [[ ! -x "$nfpm_bin" ]]; then
    local version="2.38.0"
    local archive="$TOOLS_DIR/nfpm_${version}_Linux_${nfpm_arch}.tar.gz"
    download "https://github.com/goreleaser/nfpm/releases/download/v${version}/nfpm_${version}_Linux_${nfpm_arch}.tar.gz" "$archive"
    rm -rf "$nfpm_dir"
    mkdir -p "$nfpm_dir"
    tar -C "$nfpm_dir" -xzf "$archive"
  fi
}

ensure_macos_host_tools
ensure_flutter
ensure_python
ensure_go
ensure_rust
ensure_java
ensure_nFpm

cat <<EOF
Bootstrap complete.

Add these to your shell for the current session:
  export PATH="$TOOLS_DIR/flutter/bin:$TOOLS_DIR/python/bin:$TOOLS_DIR/go/bin:$TOOLS_DIR/cargo/bin:$TOOLS_DIR/java/bin:$TOOLS_DIR/nfpm:\$PATH"
  export JAVA_HOME="$TOOLS_DIR/java"
  export CARGO_HOME="$TOOLS_DIR/cargo"
  export RUSTUP_HOME="$TOOLS_DIR/rustup"
EOF
