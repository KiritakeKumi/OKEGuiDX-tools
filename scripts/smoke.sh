#!/usr/bin/env bash
#
# smoke.sh - verifies that a built tool actually runs.
#
# Same-architecture targets execute directly; Windows targets run under wine;
# riscv64 runs under QEMU (slow, so only version output is requested). The point
# is to catch "it compiled but does not start" failures, which are common when
# cross-compiling to a new architecture (TOOLS-REPO.md §6).
#
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="${1:-}"
[[ -n "$TARGET" ]] || { echo "usage: smoke.sh <target>" >&2; exit 2; }

TARGET_FILE="$ROOT/targets/$TARGET.env"
[[ -f "$TARGET_FILE" ]] || { echo "no such target: $TARGET" >&2; exit 2; }
# shellcheck source=/dev/null
source "$TARGET_FILE"

PREFIX="$ROOT/out/$TARGET"
[[ -d "$PREFIX/tools" ]] || { echo "nothing built for $TARGET" >&2; exit 1; }

# Chooses how to execute a binary for this target.
runner_for() {
    case "$TARGET" in
        linux-riscv64) echo "qemu-riscv64 -L /usr/riscv64-linux-gnu" ;;
        linux-arm64)   echo "qemu-aarch64 -L /usr/aarch64-linux-gnu" ;;
        win-*)         echo "wine" ;;
        *)             echo "" ;;
    esac
}

RUNNER="$(runner_for)"
FAILED=0
SKIPPED=0
TOTAL=0

check() {
    local bin="$1"; shift
    TOTAL=$((TOTAL + 1))
    if [[ ! -f "$bin" ]]; then
        echo "SKIP  $bin (not built)"
        SKIPPED=$((SKIPPED + 1))
        return
    fi
    local out
    if ! out=$($RUNNER "$bin" "$@" 2>&1 | head -3); then
        echo "FAIL  $bin"
        echo "$out" | sed 's/^/      /'
        FAILED=$((FAILED + 1))
        return
    fi
    echo "ok    $(basename "$bin"): $(echo "$out" | head -1)"
}

EXE="${EXE_SUFFIX:-}"

# The encoder names are variant-suffixed, and they must match what the recipes
# install and what internal/toolchain looks for: upstream installs the bare
# name, tmod and the x265 forks add a suffix. Checking only the bare name made
# every variant build SKIP, which reads as success.
check "$PREFIX/tools/x26x/x264$EXE"                     --version
check "$PREFIX/tools/x26x/x264-tmod$EXE"                --version
check "$PREFIX/tools/x26x/x265$EXE"                     --version
check "$PREFIX/tools/x26x/x265-asuna$EXE"               --version
check "$PREFIX/tools/x26x/x265-kyouko$EXE"              --version
check "$PREFIX/tools/svtav1/SvtAv1EncApp$EXE"           --version
check "$PREFIX/tools/ffmpeg/ffmpeg$EXE"                 -version
check "$PREFIX/tools/ffmpeg/ffprobe$EXE"                -version
check "$PREFIX/tools/mkvtoolnix/mkvmerge$EXE"           --version
check "$PREFIX/tools/mkvtoolnix/mkvextract$EXE"         --version
check "$PREFIX/tools/l-smash/muxer$EXE"                 --version
check "$PREFIX/tools/flac/flac$EXE"                     --version

# A target that produced no runnable binary at all is a failure, not a pass:
# every check above reports SKIP when the file is absent, so an empty or
# mis-laid-out output tree would otherwise sail through.
if [[ "$SKIPPED" -eq "$TOTAL" ]]; then
    echo "no binaries found under $PREFIX/tools; nothing was verified" >&2
    exit 1
fi

if [[ "$FAILED" -gt 0 ]]; then
    echo
    echo "$FAILED smoke test(s) failed for $TARGET" >&2
    exit 1
fi
echo
if [[ "$SKIPPED" -gt 0 ]]; then
    echo "$((TOTAL - SKIPPED))/$TOTAL smoke tests passed for $TARGET ($SKIPPED not built)"
else
    echo "all smoke tests passed for $TARGET"
fi
