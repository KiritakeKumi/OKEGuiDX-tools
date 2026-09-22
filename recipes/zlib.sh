#!/usr/bin/env bash
#
# zlib recipe - a build dependency, not a shipped tool.
#
# zlib is not in the bundle: it is a static library that ffmpeg (and, later,
# mkvtoolnix) links against. It is built as its own recipe because llvm-mingw
# does not ship zlib for the Windows targets, and the Alpine container has it
# only as a shared library, which the fully static targets cannot use.
#
# Callers reach it through require_dependency in scripts/build.sh, so a recipe
# never has to know whether the library is already in place.
#
# SPDX-License-Identifier: GPL-3.0-or-later

TOOL_NAME=zlib
# This recipe produces a static library for other recipes, not a bundled tool,
# so CI must not schedule it as a matrix entry of its own.
TOOL_IS_DEPENDENCY=1

configure() {
    cd "$SRC"
    # zlib ships a hand-written configure rather than autotools or cmake.
    # --static makes it build libz.a; --prefix points at the shared dependency
    # tree so every consumer can find it with one -I/-L pair.
    CHOST="$HOST" ./configure \
        --prefix="$DEPS" \
        --static
}

build() {
    cd "$SRC"
    make -j"$(nproc 2>/dev/null || echo 4)"
}

install() {
    cd "$SRC"
    # zlib's install target also drops a shared library on some systems, so the
    # static archive and headers are copied explicitly instead.
    make install
    if [[ ! -f "$DEPS/lib/libz.a" ]]; then
        echo "zlib: expected $DEPS/lib/libz.a after install, found:" >&2
        ls -l "$DEPS/lib" >&2
        exit 1
    fi
    ls -l "$DEPS/lib/libz.a" "$DEPS/include/zlib.h"
}
