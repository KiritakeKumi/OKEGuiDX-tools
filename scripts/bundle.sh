#!/usr/bin/env bash
#
# bundle.sh <target> - packs a target's output into the archive OKEGuiDX
# consumes.
#
# The archive layout deliberately mirrors the existing release's tools/ tree, so
# the toolchain layer in the engine can point at it without a translation step
# (TOOLS-REPO.md §4). GPL compliance material is included in every bundle.
#
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="${1:-}"
[[ -n "$TARGET" ]] || { echo "usage: bundle.sh <target>" >&2; exit 2; }

PREFIX="$ROOT/out/$TARGET"
[[ -d "$PREFIX/tools" ]] || { echo "nothing built for $TARGET" >&2; exit 1; }

DIST="$ROOT/dist"
mkdir -p "$DIST"

DATE="$(date -u +%Y%m%d)"
NAME="okeguidx-tools-$TARGET-$DATE"

STAGE="$ROOT/work/bundle/$NAME"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -r "$PREFIX/tools" "$STAGE/tools"

# --- GPL compliance --------------------------------------------------------

# x264, x265 and ffmpeg are GPL; redistributing the binaries requires being able
# to supply the corresponding source. versions.lock records the exact ref of
# every tool, and SOURCES.md restates it next to the binaries.
mkdir -p "$STAGE/LICENSES"

{
    echo "# Corresponding sources"
    echo
    echo "This bundle contains binaries built from the following sources."
    echo "Each entry is a repository URL and the exact tag or commit that was"
    echo "built, which satisfies the source-offer requirement for the GPL"
    echo "components (x264, x265, ffmpeg)."
    echo
    echo "| tool | repository | ref |"
    echo "|---|---|---|"
    awk -F'\t' '
        /^[[:space:]]*#/ { next }
        NF < 3 { next }
        { printf "| %s%s | %s | `%s` |\n", $1, ($4 != "" ? " (" $4 ")" : ""), $2, $3 }
    ' "$ROOT/versions.lock"
    echo
    echo "The recipes in recipes/ are the exact build scripts used; any patch"
    echo "applied by a recipe lives in patches/ and is part of the source."
} > "$STAGE/SOURCES.md"

cp "$ROOT/versions.lock" "$STAGE/LICENSES/versions.lock"

# --- archive --------------------------------------------------------------

cd "$ROOT/work/bundle"
if command -v zstd >/dev/null 2>&1; then
    tar --use-compress-program='zstd -19 -T0' -cf "$DIST/$NAME.tar.zst" "$NAME"
    echo "$DIST/$NAME.tar.zst"
else
    tar -czf "$DIST/$NAME.tar.gz" "$NAME"
    echo "$DIST/$NAME.tar.gz"
fi
