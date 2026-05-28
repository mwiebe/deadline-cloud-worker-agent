#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# build-smf-deploy.sh — Build a self-contained SMF deployment directory.
#
# Usage:
#   ./build-smf-deploy.sh <workspace-dir> <output-dir> [--platform linux|windows|all]
#
# On Linux, builds the Linux maturin wheel (native).
# On Windows (Git Bash/MSYS2), builds the Windows maturin wheel (native).
# With --platform all, attempts to build both (requires cross-compilation toolchain).
#
# Pure Python wheels are platform-independent and always included.
# To create a unified package, run this script on each platform targeting the
# same output directory, or use --merge to combine two platform-specific builds.
#
# Merge mode:
#   ./build-smf-deploy.sh --merge <linux-deploy-dir> <windows-deploy-dir> <output-dir>
set -euo pipefail

# --- Merge mode ---
if [ "${1:-}" = "--merge" ]; then
    if [ $# -lt 4 ]; then
        echo "Merge usage: $0 --merge <linux-deploy-dir> <windows-deploy-dir> <output-dir>"
        exit 1
    fi
    LINUX_DIR="$2"
    WINDOWS_DIR="$3"
    OUTPUT_DIR="$4"

    if [ ! -d "$LINUX_DIR/wheels" ]; then
        echo "ERROR: $LINUX_DIR/wheels not found. Run build on Linux first."
        exit 1
    fi
    if [ ! -d "$WINDOWS_DIR/wheels" ]; then
        echo "ERROR: $WINDOWS_DIR/wheels not found. Run build on Windows first."
        exit 1
    fi

    mkdir -p "$OUTPUT_DIR/wheels"
    cp "$LINUX_DIR/wheels"/*.whl "$OUTPUT_DIR/wheels/"
    cp "$WINDOWS_DIR/wheels"/*.whl "$OUTPUT_DIR/wheels/"
    # Deduplicate pure Python wheels (same file from both builds)
    # Keep one copy of each unique wheel name
    local_dedup=$(ls "$OUTPUT_DIR/wheels"/*.whl | sort | uniq -d 2>/dev/null || true)

    # Copy supporting files
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    cp "$SCRIPT_DIR/host-config-template.sh" "$OUTPUT_DIR/"
    cp "$SCRIPT_DIR/host-config-template.ps1" "$OUTPUT_DIR/"
    cp "$SCRIPT_DIR/deploy.py" "$OUTPUT_DIR/"
    cp "$SCRIPT_DIR/smf-deploy-README.md" "$OUTPUT_DIR/README.md"
    chmod +x "$OUTPUT_DIR/deploy.py"

    echo ""
    echo "Unified deployment directory ready: $OUTPUT_DIR"
    echo "Wheels:"
    ls -1 "$OUTPUT_DIR/wheels/"
    exit 0
fi

# --- Normal build mode ---
if [ $# -lt 2 ]; then
    echo "Usage: $0 <workspace-dir> <output-dir> [--platform linux|windows|all]"
    echo "       $0 --merge <linux-dir> <windows-dir> <output-dir>"
    exit 1
fi

WORKSPACE_DIR="$(cd "$1" && pwd)"
OUTPUT_DIR="$2"
shift 2
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Parse --platform flag
PLATFORM="auto"
while [ $# -gt 0 ]; do
    case "$1" in
        --platform) PLATFORM="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# Auto-detect platform
if [ "$PLATFORM" = "auto" ]; then
    case "$(uname -s)" in
        MINGW*|MSYS*|CYGWIN*) PLATFORM="windows" ;;
        *) PLATFORM="linux" ;;
    esac
    echo "Auto-detected platform: $PLATFORM"
fi

ERRORS=()
WARNINGS=()

# --- Prerequisite checks ---

check_repo() {
    local dir="$1" branch="$2"
    if [ ! -d "$dir/.git" ]; then
        ERRORS+=("Missing repo: $dir")
        return
    fi
    local actual
    actual=$(git -C "$dir" rev-parse --abbrev-ref HEAD)
    if [ "$actual" != "$branch" ]; then
        WARNINGS+=("$dir: expected branch '$branch', on '$actual'")
    fi
}

check_repo "$WORKSPACE_DIR/openjd-rs" main
check_repo "$WORKSPACE_DIR/openjd-model-for-python" bindings-rs
check_repo "$WORKSPACE_DIR/openjd-sessions-for-python" bindings-rs
check_repo "$WORKSPACE_DIR/deadline-cloud-worker-agent" bindings-rs
check_repo "$WORKSPACE_DIR/deadline-cloud" mainline

for cmd in rustc cargo pip; do
    if ! command -v "$cmd" &>/dev/null; then
        ERRORS+=("Missing command: $cmd")
    fi
done

if ! command -v maturin &>/dev/null; then
    ERRORS+=("Missing command: maturin (install with: pip install maturin)")
fi

if [ ${#WARNINGS[@]} -gt 0 ]; then
    echo "Warnings:"
    for w in "${WARNINGS[@]}"; do echo "  - $w"; done
fi

if [ ${#ERRORS[@]} -gt 0 ]; then
    echo "Prerequisite check failed:"
    for e in "${ERRORS[@]}"; do echo "  - $e"; done
    exit 1
fi

# --- Build maturin wheel(s) ---
#
# openjd-model uses an in-tree PEP 517 build backend (`_build_backend.py`)
# that injects a VCS-derived version into the wheel metadata, so plain
# `pip wheel` produces the same `0.9.1.post<N>+g<hash>` wheel that
# `python scripts/maturin_build.py build` does. Cross-compile targets are
# forwarded to maturin via the MATURIN_PEP517_ARGS env var.

build_maturin_linux() {
    echo "Building openjd-model wheel (maturin) for Linux..."
    (cd "$WORKSPACE_DIR/openjd-model-for-python" && pip wheel --no-deps -w dist .)
    MODEL_WHL_LINUX=$(ls -t "$WORKSPACE_DIR/openjd-model-for-python/dist"/openjd_model-*linux*.whl 2>/dev/null | head -1)
    if [ -z "${MODEL_WHL_LINUX:-}" ]; then
        # Fallback: grab the most recent wheel (native build on Linux won't have "linux" in name until auditwheel)
        MODEL_WHL_LINUX=$(ls -t "$WORKSPACE_DIR/openjd-model-for-python/dist"/openjd_model-*.whl | head -1)
    fi
}

build_maturin_windows() {
    local pep517_env=""
    # If not on Windows, cross-compile
    if [[ "$(uname -s)" != MINGW* && "$(uname -s)" != MSYS* && "$(uname -s)" != CYGWIN* ]]; then
        if ! rustup target list --installed | grep -q "x86_64-pc-windows-msvc"; then
            echo "ERROR: Rust target x86_64-pc-windows-msvc not installed."
            echo "  Run: rustup target add x86_64-pc-windows-msvc"
            exit 1
        fi
        pep517_env='MATURIN_PEP517_ARGS=--target x86_64-pc-windows-msvc'
    fi
    echo "Building openjd-model wheel (maturin) for Windows..."
    (cd "$WORKSPACE_DIR/openjd-model-for-python" && env $pep517_env pip wheel --no-deps -w dist .)
    MODEL_WHL_WINDOWS=$(ls -t "$WORKSPACE_DIR/openjd-model-for-python/dist"/openjd_model-*win*.whl 2>/dev/null | head -1)
    if [ -z "${MODEL_WHL_WINDOWS:-}" ]; then
        MODEL_WHL_WINDOWS=$(ls -t "$WORKSPACE_DIR/openjd-model-for-python/dist"/openjd_model-*.whl | head -1)
    fi
}

case "$PLATFORM" in
    linux)   build_maturin_linux ;;
    windows) build_maturin_windows ;;
    all)     build_maturin_linux; build_maturin_windows ;;
    *)       echo "Unknown platform: $PLATFORM"; exit 1 ;;
esac

# --- Build pure Python wheels ---

echo "Building openjd-sessions wheel..."
(cd "$WORKSPACE_DIR/openjd-sessions-for-python" && pip wheel --no-deps -w dist .)
SESSIONS_WHL=$(ls -t "$WORKSPACE_DIR/openjd-sessions-for-python/dist"/openjd_sessions-*.whl | head -1)

echo "Building deadline-cloud-worker-agent wheel..."
(cd "$WORKSPACE_DIR/deadline-cloud-worker-agent" && pip wheel --no-deps -w dist .)
AGENT_WHL=$(ls -t "$WORKSPACE_DIR/deadline-cloud-worker-agent/dist"/deadline_cloud_worker_agent-*.whl | head -1)

echo "Building deadline (deadline-cloud) wheel..."
(cd "$WORKSPACE_DIR/deadline-cloud" && pip wheel --no-deps -w dist .)
DEADLINE_WHL=$(ls -t "$WORKSPACE_DIR/deadline-cloud/dist"/deadline-*.whl | head -1)

# --- Assemble output directory ---

mkdir -p "$OUTPUT_DIR/wheels"

# Copy platform-specific maturin wheels
if [ -n "${MODEL_WHL_LINUX:-}" ]; then
    cp "$MODEL_WHL_LINUX" "$OUTPUT_DIR/wheels/"
fi
if [ -n "${MODEL_WHL_WINDOWS:-}" ]; then
    cp "$MODEL_WHL_WINDOWS" "$OUTPUT_DIR/wheels/"
fi

# Copy pure Python wheels
cp "$SESSIONS_WHL" "$AGENT_WHL" "$DEADLINE_WHL" "$OUTPUT_DIR/wheels/"

# Copy templates and deploy script
cp "$SCRIPT_DIR/host-config-template.sh" "$OUTPUT_DIR/"
cp "$SCRIPT_DIR/host-config-template.ps1" "$OUTPUT_DIR/"
cp "$SCRIPT_DIR/deploy.py" "$OUTPUT_DIR/"
cp "$SCRIPT_DIR/smf-deploy-README.md" "$OUTPUT_DIR/README.md"
chmod +x "$OUTPUT_DIR/deploy.py"

echo ""
echo "Deployment directory ready: $OUTPUT_DIR"
echo "Wheels:"
ls -1 "$OUTPUT_DIR/wheels/"
echo ""
if [ "$PLATFORM" != "all" ]; then
    echo "NOTE: Only $PLATFORM maturin wheel included. To create a unified package:"
    echo "  1. Run this script on the other platform targeting a separate output dir"
    echo "  2. Merge with: $0 --merge <linux-dir> <windows-dir> <unified-dir>"
fi
