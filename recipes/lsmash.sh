#!/usr/bin/env bash
#
# l-smash recipe - the simplest tool, used to validate the CI skeleton.
#
# l-smash has no external dependencies, so a working build here proves that the
# toolchain, the environment file and the install layout are all correct
# (TOOLS-REPO.md §5, C1).
#
# Two details differ from a stock autotools recipe:
#
#   * l-smash's configure is hand-written, not autotools. It has no --host and
#     no --enable-static/--disable-shared; the cross target is selected with
#     --target-os and the toolchain with --cross-prefix. Passing --host made
#     configure abort with "unknown option --host=..." on every target, which is
#     why this recipe failed on all five from the first CI run.
#   * It installs its CLIs into <prefix>/bin by default, but the engine looks
#     for tools/l-smash/muxer flat (internal/toolchain/toolchain.go, and
#     scripts/smoke.sh checks the same path), so --bindir is pointed at the
#     tool directory itself.
#
# --cc is deliberately NOT passed: configure builds every tool name itself as
# CC="${CROSS}${CC}", so giving it a prefixed --cc as well doubles the prefix
# (riscv64-linux-gnu-riscv64-linux-gnu-gcc). --cross-prefix alone is enough, and
# it covers ar/ld/ranlib/strip the same way.
#
# SPDX-License-Identifier: GPL-3.0-or-later

TOOL_NAME=lsmash

# l-smash's configure spells the target OS its own way: it lowercases the value
# and matches *mingw* for Windows, *linux* elsewhere. It is not the autoconf
# triplet.
LSMASH_OS=linux
[[ "$CMAKE_SYSTEM_NAME" == Windows ]] && LSMASH_OS=mingw

configure() {
    cd "$SRC"
    ./configure \
        --prefix="$PREFIX/tools/l-smash" \
        --bindir="$PREFIX/tools/l-smash" \
        --target-os="$LSMASH_OS" \
        --cross-prefix="$CROSS_PREFIX" \
        --extra-cflags="-O2 -fPIC"
}

build() {
    cd "$SRC"
    make -j"$(nproc 2>/dev/null || echo 4)"
}

install() {
    cd "$SRC"
    mkdir -p "$PREFIX/tools/l-smash"
    make install
    # Fail loudly if the layout ever drifts again: the engine finds this file by
    # exactly this path, and a missing binary only shows up in smoke.sh as a
    # "not built" SKIP, which reads as success.
    local exe
    for exe in muxer remuxer; do
        if [[ ! -f "$PREFIX/tools/l-smash/$exe${EXE_SUFFIX:-}" ]]; then
            echo "l-smash: expected $PREFIX/tools/l-smash/$exe${EXE_SUFFIX:-}, found:" >&2
            ls -l "$PREFIX/tools/l-smash" >&2
            exit 1
        fi
    done
    ls -l "$PREFIX/tools/l-smash"
}
