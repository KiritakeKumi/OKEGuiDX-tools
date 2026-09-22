#!/usr/bin/env bash
#
# build.sh <recipe> <target> [variant]
#
# Builds one external tool for one target. The recipe is a plain shell script
# exporting fetch/configure/build/install; the target supplies the toolchain
# through targets/<target>.env. No build framework, no DSL: the whole point is
# that a recipe can be read and debugged by hand (TOOLS-REPO.md §4).
#
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

RECIPE="${1:-}"
TARGET="${2:-}"
VARIANT="${3:-}"

if [[ -z "$RECIPE" || -z "$TARGET" ]]; then
    echo "usage: build.sh <recipe> <target> [variant]" >&2
    echo "  recipes: $(cd "$ROOT/recipes" 2>/dev/null && ls *.sh 2>/dev/null | sed 's/\.sh$//' | tr '\n' ' ')" >&2
    echo "  targets: $(cd "$ROOT/targets" 2>/dev/null && ls *.env 2>/dev/null | sed 's/\.env$//' | tr '\n' ' ')" >&2
    exit 2
fi

RECIPE_FILE="$ROOT/recipes/$RECIPE.sh"
TARGET_FILE="$ROOT/targets/$TARGET.env"

[[ -f "$RECIPE_FILE" ]] || { echo "no such recipe: $RECIPE" >&2; exit 2; }
[[ -f "$TARGET_FILE" ]]  || { echo "no such target: $TARGET" >&2; exit 2; }

# shellcheck source=/dev/null
source "$TARGET_FILE"
# shellcheck source=/dev/null
source "$RECIPE_FILE"

# Everything below is exported to the recipe's functions.
export TARGET VARIANT ROOT
export CC CXX AR RANLIB STRIP
export CFLAGS CXXFLAGS LDFLAGS
export CMAKE_SYSTEM_NAME CMAKE_SYSTEM_PROCESSOR CROSS_PREFIX HOST
export EXE_SUFFIX="${EXE_SUFFIX:-}"
export WINDRES="${WINDRES:-}"

WORK="$ROOT/work/$TARGET/$RECIPE${VARIANT:+-$VARIANT}"
SRC="$WORK/src"
PREFIX="$ROOT/out/$TARGET"
# DEPS is the shared dependency tree for a target: static libraries that recipes
# link against but that are not shipped in the bundle, such as zlib.
DEPS="$ROOT/out/$TARGET/deps"
export WORK SRC PREFIX DEPS

mkdir -p "$WORK" "$PREFIX" "$DEPS"

# The version to build comes from versions.lock, which is the only place a
# version is recorded. The variant selects between two builds of one tool.
lookup_ref() {
    local tool="$1" variant="$2"
    awk -F'\t' -v t="$tool" -v v="$variant" '
        /^[[:space:]]*#/ { next }
        NF < 3 { next }
        $1 == t && $4 == v { print $3; exit }
    ' "$ROOT/versions.lock"
}

lookup_repo() {
    local tool="$1" variant="$2"
    awk -F'\t' -v t="$tool" -v v="$variant" '
        /^[[:space:]]*#/ { next }
        NF < 3 { next }
        $1 == t && $4 == v { print $2; exit }
    ' "$ROOT/versions.lock"
}

# Recipes may set these; the defaults come from versions.lock.
: "${TOOL_NAME:=$RECIPE}"
: "${TOOL_VARIANT:=$VARIANT}"
TOOL_REPO="${TOOL_REPO:-$(lookup_repo "$TOOL_NAME" "$TOOL_VARIANT")}"
TOOL_REF="${TOOL_REF:-$(lookup_ref "$TOOL_NAME" "$TOOL_VARIANT")}"

if [[ -z "$TOOL_REPO" || -z "$TOOL_REF" ]]; then
    echo "versions.lock has no entry for $TOOL_NAME variant='$TOOL_VARIANT'" >&2
    exit 1
fi

export TOOL_NAME TOOL_REPO TOOL_REF

echo "=== building $TOOL_NAME ($TOOL_REF${TOOL_VARIANT:+, $TOOL_VARIANT}) for $TARGET"
echo "    repo:   $TOOL_REPO"
echo "    work:   $WORK"
echo "    prefix: $PREFIX"

# --- dependencies -----------------------------------------------------------

# require_dependency <tool>
#
# Builds another recipe for the same target unless its library is already in
# place. Recipes call this instead of assuming the dependency exists, which
# keeps the ordering out of the CI workflow and makes a local build work the
# same way. The dependency is built with the same target environment and the
# same variant, so its toolchain matches.
require_dependency() {
    local dep="$1"
    if [[ -f "$DEPS/lib/lib${dep}.a" ]]; then
        echo "    dependency $dep already built"
        return
    fi
    echo "    building dependency $dep"
    # The child must look the dependency up itself. This script has already
    # exported TOOL_NAME/TOOL_REPO/TOOL_REF for the *parent* tool, and a child
    # process inherits them, so the child's `: "${TOOL_REPO:=...}"` never
    # consulted versions.lock: zlib was silently cloned from the FFmpeg tree
    # (and, under mkvtoolnix, from the mkvtoolnix tarball directory) and then
    # failed on a configure option that tool does not have.
    env -u TOOL_NAME -u TOOL_REPO -u TOOL_REF -u TOOL_VARIANT \
        "$ROOT/scripts/build.sh" "$dep" "$TARGET" "${VARIANT:-}" >&2
}

# --- fetch -----------------------------------------------------------------

# Clones the exact ref. A cached clone is reused when present so that repeated
# builds do not re-download; the ref is checked out explicitly every time.
default_fetch() {
    if [[ -d "$SRC/.git" ]]; then
        git -C "$SRC" fetch --tags --force origin
    else
        rm -rf "$SRC"
        git clone --no-checkout "$TOOL_REPO" "$SRC"
    fi
    git -C "$SRC" checkout --force "$TOOL_REF"
    git -C "$SRC" submodule update --init --recursive --depth 1 || true
    # Record the exact commit so the build log is auditable.
    echo "    commit: $(git -C "$SRC" rev-parse HEAD)"
}

if declare -F fetch >/dev/null; then fetch; else default_fetch; fi

# --- configure / build / install -------------------------------------------

if ! declare -F configure >/dev/null; then
    echo "recipe $RECIPE does not define configure()" >&2
    exit 1
fi
if ! declare -F build >/dev/null; then
    echo "recipe $RECIPE does not define build()" >&2
    exit 1
fi
if ! declare -F install >/dev/null; then
    echo "recipe $RECIPE does not define install()" >&2
    exit 1
fi

configure
build
install

echo "=== done: $TOOL_NAME -> $PREFIX"
