#!/usr/bin/env bash
#
# flac recipe - the lossless audio codec used by the audio pipeline.
#
# FLAC has no external dependencies, so this is a plain CMake build. Two of
# upstream's defaults have to be turned off for a git checkout to configure at
# all: Ogg support wants a libogg to link against, and man pages want either
# pandoc or prebuilt files, neither of which exists in a git tree (the tarball
# release ships the generated man pages, the repository does not).
#
# The CLI is installed straight into tools/flac/ so that the engine's toolchain
# layer finds it without a translation step (TOOLS-REPO.md §4).
#
# SPDX-License-Identifier: GPL-3.0-or-later

TOOL_NAME=flac

configure() {
    cd "$SRC"

    local args=(
        -S . -B build
        -DCMAKE_BUILD_TYPE=Release
        -DCMAKE_INSTALL_PREFIX="$PREFIX/tools/flac"
        # Installing into the bindir itself yields tools/flac/flac instead of
        # tools/flac/bin/flac, which is the layout the engine expects.
        -DCMAKE_INSTALL_BINDIR=.
        -DCMAKE_SYSTEM_NAME="$CMAKE_SYSTEM_NAME"
        -DCMAKE_SYSTEM_PROCESSOR="$CMAKE_SYSTEM_PROCESSOR"
        -DCMAKE_C_COMPILER="$CC"
        -DCMAKE_CXX_COMPILER="$CXX"
        # libFLAC is linked into the CLI; nothing is shipped as a shared object.
        -DBUILD_SHARED_LIBS=OFF
        -DBUILD_PROGRAMS=ON
        -DBUILD_CXXLIBS=OFF
        -DBUILD_EXAMPLES=OFF
        -DBUILD_TESTING=OFF
        -DBUILD_DOCS=OFF
        # The engine only ever handles native FLAC streams, never Ogg FLAC.
        -DWITH_OGG=OFF
        # No pandoc in CI and no prebuilt man pages in a git checkout.
        -DINSTALL_MANPAGES=OFF
        -DINSTALL_PKGCONFIG_MODULES=OFF
        -DINSTALL_CMAKE_CONFIG_MODULE=OFF
        # metaflac links the bundled replaygain analysis object, which calls
        # log10(); without -lm the link fails on glibc with "undefined reference
        # to `log10'". LDFLAGS from the target env are not used for the CMake
        # link line here, so the flag has to be passed explicitly.
        -DCMAKE_EXE_LINKER_FLAGS="-lm"
    )

    # The Windows targets ship a version resource, which CMake compiles with
    # windres; the Linux targets have no RC compiler and no RC source.
    if [[ -n "${WINDRES:-}" ]]; then
        args+=(-DCMAKE_RC_COMPILER="$WINDRES")
    fi

    if [[ "$CMAKE_SYSTEM_NAME" == "Windows" ]]; then
        # FLAC enables multithreading, so CMake links the Threads library. On
        # MinGW it emits -Wl,-Bdynamic right before -pthread, which makes the
        # import library win and leaves the binary needing libwinpthread-1.dll
        # next to it. Ending the library search in static mode keeps the result
        # self-contained, which is the whole point of the static targets.
        args+=(-DCMAKE_LINK_SEARCH_END_STATIC=TRUE)
    fi

    cmake "${args[@]}"
}

build() {
    cd "$SRC"
    cmake --build build --parallel "$(nproc 2>/dev/null || echo 4)"
}

install() {
    cd "$SRC"
    mkdir -p "$PREFIX/tools/flac"
    cmake --install build

    # Fail loudly here rather than at smoke-test time if upstream ever renames
    # the target or changes where it installs.
    local exe="$PREFIX/tools/flac/flac${EXE_SUFFIX:-}"
    if [[ ! -f "$exe" ]]; then
        echo "flac: expected $exe after install, found:" >&2
        ls -l "$PREFIX/tools/flac" >&2
        exit 1
    fi
    ls -l "$PREFIX/tools/flac"
}
