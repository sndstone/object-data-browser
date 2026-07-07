#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS_DIR="$ROOT_DIR/.tmp/toolchains"
ENGINE_SOURCE_DIR="$ROOT_DIR/engines"
RELEASE_DIR=""
ARCH="$(uname -m)"
HELP=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --release-dir)
      RELEASE_DIR="$2"
      shift 2
      ;;
    --tools-dir)
      TOOLS_DIR="$2"
      shift 2
      ;;
    --arch)
      ARCH="$2"
      shift 2
      ;;
    --help)
      HELP=1
      shift
      ;;
    *)
      echo "Unknown stage option: $1" >&2
      exit 1
      ;;
  esac
done

if [[ "$HELP" -eq 1 || -z "$RELEASE_DIR" ]]; then
  cat <<EOF
Usage:
  ./scripts/stage-engines.sh --release-dir <flutter-release-dir-or-app> [--tools-dir <tool-dir>] [--arch <arch>]
EOF
  [[ "$HELP" -eq 1 ]] && exit 0
  exit 1
fi

if [[ ! -e "$RELEASE_DIR" ]]; then
  echo "Flutter release directory was not found at $RELEASE_DIR." >&2
  exit 1
fi

remove_directory_if_exists() {
  local path="$1"
  if [[ -e "$path" ]]; then
    rm -rf "$path"
  fi
}

copy_directory_content() {
  local source_dir="$1"
  local destination_dir="$2"
  mkdir -p "$destination_dir"
  cp -R "$source_dir"/. "$destination_dir"/
}

ensure_command() {
  local name="$1"
  if ! command -v "$name" >/dev/null 2>&1; then
    echo "Required command '$name' is not available in PATH." >&2
    exit 1
  fi
}

resolve_stage_root() {
  if [[ "$RELEASE_DIR" == *.app ]]; then
    printf '%s\n' "$RELEASE_DIR/Contents/Resources/engines"
  else
    printf '%s\n' "$RELEASE_DIR/engines"
  fi
}

STAGE_ROOT="$(resolve_stage_root)"
remove_directory_if_exists "$STAGE_ROOT"
mkdir -p "$STAGE_ROOT"

stage_python_engine() {
  local python_exe=""
  if [[ -x "$TOOLS_DIR/python/bin/python3" ]]; then
    python_exe="$TOOLS_DIR/python/bin/python3"
  elif command -v python3 >/dev/null 2>&1; then
    python_exe="$(command -v python3)"
  else
    echo "Python runtime was not found in $TOOLS_DIR/python or PATH." >&2
    exit 1
  fi

  local python_dest="$STAGE_ROOT/python"
  local site_packages_dir="$python_dest/site-packages"
  remove_directory_if_exists "$python_dest"
  mkdir -p "$python_dest/engine" "$site_packages_dir"

  if [[ -d "$TOOLS_DIR/python" ]]; then
    copy_directory_content "$TOOLS_DIR/python" "$python_dest"
    site_packages_dir="$python_dest/site-packages"
    mkdir -p "$site_packages_dir"
    python_exe="$python_dest/bin/python3"
  fi

  cp "$ENGINE_SOURCE_DIR/python/src/main.py" "$python_dest/engine/main.py"

  "$python_exe" -m pip install \
    --disable-pip-version-check \
    --no-compile \
    --upgrade \
    --target "$site_packages_dir" \
    boto3 \
    botocore \
    s3transfer \
    jmespath \
    python-dateutil \
    urllib3 \
    six

  cat >"$python_dest/run-python-engine.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLED_PYTHON="$SCRIPT_DIR/bin/python3"
if [[ -x "$BUNDLED_PYTHON" ]]; then
  PYTHON_CMD="$BUNDLED_PYTHON"
elif command -v python3 >/dev/null 2>&1; then
  PYTHON_CMD="$(command -v python3)"
elif command -v python >/dev/null 2>&1; then
  PYTHON_CMD="$(command -v python)"
else
  echo "Python 3 is required to run the packaged Python sidecar." >&2
  exit 127
fi
export PYTHONPATH="$SCRIPT_DIR/site-packages${PYTHONPATH:+:$PYTHONPATH}"
exec "$PYTHON_CMD" "$SCRIPT_DIR/engine/main.py" "$@"
EOF
  chmod +x "$python_dest/run-python-engine.sh"
}

stage_go_engine() {
  ensure_command go
  local go_dest="$STAGE_ROOT/go"
  local go_build_dir="$ENGINE_SOURCE_DIR/go/build/$ARCH"
  local go_binary="$go_build_dir/s3-browser-go-engine"
  local go_arch=""
  local go_os=""

  case "$ARCH" in
    x64|amd64|x86_64)
      go_arch="amd64"
      ;;
    arm64|aarch64)
      go_arch="arm64"
      ;;
    *)
      echo "Unsupported Go architecture for sidecar staging: $ARCH" >&2
      exit 1
      ;;
  esac

  case "$(uname -s)" in
    Linux)
      go_os="linux"
      ;;
    Darwin)
      go_os="darwin"
      ;;
    *)
      echo "Unsupported host OS for Go sidecar staging: $(uname -s)" >&2
      exit 1
      ;;
  esac

  remove_directory_if_exists "$go_dest"
  remove_directory_if_exists "$go_build_dir"
  mkdir -p "$go_dest"
  mkdir -p "$go_build_dir"
  (
    cd "$ENGINE_SOURCE_DIR/go"
    echo "Building Go engine for $go_os/$go_arch..."
    GOOS="$go_os" GOARCH="$go_arch" CGO_ENABLED=0 \
      go build -trimpath -ldflags "-s -w" -o "$go_binary" ./src
  )

  if [[ ! -f "$go_binary" ]]; then
    local artifacts
    artifacts="$(find "$ENGINE_SOURCE_DIR/go" -type f \( -name '*.exe' -o -name 's3-browser-go-engine' \) | sort || true)"
    if [[ -z "$artifacts" ]]; then
      artifacts="No Go engine binaries were found under $ENGINE_SOURCE_DIR/go."
    fi
    echo "Go engine build did not produce the expected binary at $go_binary." >&2
    echo "$artifacts" >&2
    exit 1
  fi

  cp "$go_binary" "$go_dest/s3-browser-go-engine"
}

stage_rust_engine() {
  ensure_command cargo
  local rust_source="$ENGINE_SOURCE_DIR/rust"
  local rust_dest="$STAGE_ROOT/rust"
  remove_directory_if_exists "$rust_dest"
  mkdir -p "$rust_dest"
  (
    cd "$rust_source"
    cargo build --release
  )
  cp "$rust_source/target/release/s3-browser-rust-engine" "$rust_dest/s3-browser-rust-engine"
}

stage_java_engine() {
  local java_source="$ENGINE_SOURCE_DIR/java"
  local java_dest="$STAGE_ROOT/java"
  local runtime_source=""
  local gradle_wrapper="$ROOT_DIR/apps/flutter_app/android/gradlew"

  if [[ -d "$TOOLS_DIR/java" ]]; then
    runtime_source="$TOOLS_DIR/java"
  elif [[ -n "${JAVA_HOME:-}" && -d "$JAVA_HOME" ]]; then
    runtime_source="$JAVA_HOME"
  else
    echo "A Java runtime directory was not found in \$TOOLS_DIR/java or \$JAVA_HOME." >&2
    exit 1
  fi

  remove_directory_if_exists "$java_dest"
  mkdir -p "$java_dest"

  if [[ -f "$gradle_wrapper" && ! -x "$gradle_wrapper" ]]; then
    chmod +x "$gradle_wrapper"
  fi

  if [[ ! -x "$gradle_wrapper" ]]; then
    echo "Gradle wrapper was not found at $gradle_wrapper." >&2
    exit 1
  fi

  copy_directory_content "$runtime_source" "$java_dest/runtime"

  (
    cd "$ROOT_DIR/apps/flutter_app/android"
    ./gradlew -p "$java_source" installDist --no-daemon
  )

  copy_directory_content "$java_source/build/install/s3-browser-java-engine/lib" "$java_dest/lib"

  cat >"$java_dest/run-java-engine.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JAVA_CMD="$SCRIPT_DIR/runtime/bin/java"
if [[ ! -x "$JAVA_CMD" ]]; then
  if command -v java >/dev/null 2>&1; then
    JAVA_CMD="$(command -v java)"
  else
    echo "Java is required to run the packaged Java sidecar." >&2
    exit 127
  fi
fi
exec "$JAVA_CMD" -cp "$SCRIPT_DIR/lib/*" com.example.s3browser.Main "$@"
EOF
  chmod +x "$java_dest/run-java-engine.sh"
}

get_app_version() {
  local pubspec_path="$ROOT_DIR/apps/flutter_app/pubspec.yaml"
  local version="0.0.0"
  if [[ -f "$pubspec_path" ]]; then
    local match
    match="$(sed -n 's/^version:[[:space:]]*\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' "$pubspec_path" | head -n 1)"
    if [[ -n "$match" ]]; then
      version="$match"
    fi
  fi
  printf '%s\n' "$version"
}

write_manifest() {
  local manifest_path="$STAGE_ROOT/manifest.json"
  local manifest_python="$TOOLS_DIR/python/bin/python3"
  if [[ ! -x "$manifest_python" ]]; then
    manifest_python="$(command -v python3)"
  fi
  local app_version
  app_version="$(get_app_version)"
  "$manifest_python" - "$manifest_path" "$ARCH" "$app_version" <<'PY'
import json
import sys

manifest_path = sys.argv[1]
arch = sys.argv[2]
app_version = sys.argv[3]
manifest = {
    "version": app_version,
    "architecture": arch,
    "generatedAt": __import__("datetime").datetime.now(__import__("datetime").timezone.utc).isoformat(),
    "engines": [
        {
            "id": "python",
            "version": app_version,
            "executable": "python/run-python-engine.sh",
            "arguments": [],
            "workingDirectory": "python",
            "requiredFiles": [
                "python/run-python-engine.sh",
                "python/engine/main.py",
            ],
        },
        {
            "id": "go",
            "version": app_version,
            "executable": "go/s3-browser-go-engine",
            "arguments": [],
            "workingDirectory": "go",
            "requiredFiles": [
                "go/s3-browser-go-engine",
            ],
        },
        {
            "id": "rust",
            "version": app_version,
            "executable": "rust/s3-browser-rust-engine",
            "arguments": [],
            "workingDirectory": "rust",
            "requiredFiles": [
                "rust/s3-browser-rust-engine",
            ],
        },
        {
            "id": "java",
            "version": app_version,
            "executable": "java/run-java-engine.sh",
            "arguments": [],
            "workingDirectory": "java",
            "requiredFiles": [
                "java/run-java-engine.sh",
                "java/lib",
                "java/runtime/bin/java",
            ],
        },
    ],
}
with open(manifest_path, "w", encoding="utf-8") as handle:
    json.dump(manifest, handle, indent=2)
PY
}

stage_python_engine
stage_go_engine
stage_rust_engine
stage_java_engine
write_manifest

echo "Staged desktop engine sidecars into $STAGE_ROOT"
