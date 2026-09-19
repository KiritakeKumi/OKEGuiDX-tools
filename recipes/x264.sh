#!/usr/bin/env bash
#
# x264 recipe - H.264 encoder CLI.
#
# Two flavours come from versions.lock and share this recipe (TOOLS-REPO.md §3):
#
#   upstream  videolan/x264, the modern line with NEON/SVE/SVE2 assembly.
#             Built for every target.
#   tmod      jpsdr/x264, the x86-oriented fork the current Windows release
#             ships. Built for win-x64 only, where the engine prefers it.
#
# The installed file name depends on the flavour and must stay in sync with
# internal/toolchain/toolchain.go: upstream installs `x264`, tmod installs
# `x264-tmod`, both with `.exe` on Windows. The engine tries those names in
# that order on win-x64, so shipping both keeps the release-compatible default.
#
# SPDX-License-Identifier: GPL-3.0-or-later

TOOL_NAME=x264

# x264 bundles a config.sub from 2012, which predates riscv64: the plain
# `riscv64-linux-gnu` triplet in targets/linux-riscv64.env is rejected with
# "machine `riscv64' not recognized", after which configure dies with an
# unrelated "Unknown system" error. Spelling the vendor out as `unknown` takes
# config.sub's wildcard branch and still splits into host_cpu=riscv64 /
# host_os=linux, which lands on the generic ARCH fallback. Upstream has no
# RISC-V assembly, so that target is a plain C build.
host_triplet() {
    case "$HOST" in
        riscv64-unknown-*) echo "$HOST" ;;
        riscv64-*)         echo "riscv64-unknown-${HOST#riscv64-}" ;;
        *)                 echo "$HOST" ;;
    esac
}

# tmod's filters/video/subtitles.c includes <Windows.h> with a capital W, but
# mingw-w64 ships only lowercase windows.h and the CI filesystem is
# case-sensitive, so the win-x64 cross build fails to find the header. Windows
# compilers never notice, which is why upstream never had to fix it.
#
# build.sh reuses work/<target>/<recipe>-<variant>/src between runs and
# re-checks out the ref every time, so the patch is applied from a clean tree;
# the already-applied check keeps a manually patched tree from erroring.
apply_patches() {
    local patch="$ROOT/patches/x264-tmod-windows-h-case.patch"
    [[ -f "$patch" ]] || { echo "missing patch: $patch" >&2; return 1; }
    if git -C "$SRC" apply --reverse --check "$patch" >/dev/null 2>&1; then
        echo "    patch already applied: $(basename "$patch")"
        return 0
    fi
    git -C "$SRC" apply --verbose "$patch"
}

fetch() {
    default_fetch
    if [[ "${TOOL_VARIANT:-}" == "tmod" ]]; then
        apply_patches
    fi
}

configure() {
    cd "$SRC"

    # --enable-pic is what upstream's own CI passes for every target. On x86-64
    # nasm forces PIC anyway; on aarch64 it selects the adrp/:lo12: form of
    # movrel in asm.S, which is the one that is correct for COFF.
    local args=(
        --prefix="$PREFIX/tools/x26x"
        --host="$(host_triplet)"
        --cross-prefix="$CROSS_PREFIX"
        --enable-static
        --enable-pic
    )

    # tmod also carries audio encoders and libavformat-backed AVI output. The
    # engine feeds x264 a y4m pipe and muxes audio separately, so both are dead
    # weight; disabling them keeps the build independent of whichever libraries
    # happen to be visible to the cross toolchain.
    if [[ "${TOOL_VARIANT:-}" == "tmod" ]]; then
        args+=( --disable-audio --disable-avi-output )
    fi

    ./configure "${args[@]}"
}

build() {
    cd "$SRC"
    make -j"$(nproc 2>/dev/null || echo 4)"
}

install() {
    cd "$SRC"

    local name="x264"
    [[ "${TOOL_VARIANT:-}" == "tmod" ]] && name="x264-tmod"

    local bin="x264${EXE_SUFFIX:-}"
    if [[ ! -f "$bin" ]]; then
        echo "expected $bin after the build, found none in $SRC" >&2
        return 1
    fi

    mkdir -p "$PREFIX/tools/x26x"
    # Copied by hand instead of `make install`: --enable-static also builds
    # libx264.a, and installing it would scatter headers and archives into the
    # bundle's tools tree, which the engine never looks at.
    # `command` is required because this file defines a function called
    # install(), which would otherwise shadow the external tool.
    command install -m 755 "$bin" "$PREFIX/tools/x26x/$name${EXE_SUFFIX:-}"
    if [[ -n "${STRIP:-}" ]]; then
        "$STRIP" "$PREFIX/tools/x26x/$name${EXE_SUFFIX:-}"
    fi

    ls -l "$PREFIX/tools/x26x"
}
