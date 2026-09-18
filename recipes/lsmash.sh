#!/usr/bin/env bash
#
# l-smash recipe - the simplest tool, used to validate the CI skeleton.
#
# l-smash has no external dependencies, so a working build here proves that the
# toolchain, the environment file and the install layout are all correct
# (TOOLS-REPO.md §5, C1).
#
# SPDX-License-Identifier: GPL-3.0-or-later

TOOL_NAME=lsmash

configure() {
    cd "$SRC"
    ./configure \
        --prefix="$PREFIX/tools/l-smash" \
        --host="$HOST" \
        --enable-static \
        --disable-shared \
        --cross-prefix="$CROSS_PREFIX"
}

build() {
    cd "$SRC"
    make -j"$(nproc 2>/dev/null || echo 4)"
}

install() {
    cd "$SRC"
    mkdir -p "$PREFIX/tools/l-smash"
    # l-smash installs its CLI tools (muxer/remuxer) but no headers we need;
    # copying the binaries directly keeps the bundle layout predictable.
    make install
    ls -l "$PREFIX/tools/l-smash"
}
