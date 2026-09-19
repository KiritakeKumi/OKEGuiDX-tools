#!/usr/bin/env bash
#
# ffmpeg recipe - the demuxer, audio decoder and FLAC encoder every target
# platform uses.
#
# Scope, so that nobody "completes" this recipe by adding libraries: the engine
# drives these two programs for exactly four things
#   - track enumeration      ffprobe -show_streams -of json
#   - stream extraction      ffmpeg -map ... -c copy
#   - lossless audio to FLAC ffmpeg -c:a flac
#   - volume measurement     ffmpeg -af volumedetect
# Video encoders, muxers and containers have their own recipes and are driven
# as separate processes, so no --enable-lib* flag belongs here. Linking no
# third-party library at all also keeps the licence simple and the bundle
# reproducible across runners (TOOLS-REPO.md §5 and §8).
#
# ffplay is deliberately not built: it needs SDL2 and the engine never opens a
# video window.
#
# Only the two programs are copied into tools/ffmpeg/, which is where the
# engine's toolchain layer looks for them (defaultRelativePaths in
# internal/toolchain/toolchain.go). The static libraries FFmpeg produces are
# build intermediates and stay out of the bundle.
#
# SPDX-License-Identifier: GPL-3.0-or-later

TOOL_NAME=ffmpeg

configure() {
    cd "$SRC"

    # FFmpeg calls every MinGW target mingw32, including the 64-bit ones; the
    # machine is selected by --arch. These variables come from targets/*.env.
    local target_os arch
    case "${CMAKE_SYSTEM_NAME:-}" in
        Windows) target_os=mingw32 ;;
        Linux)   target_os=linux ;;
        *) echo "ffmpeg: unsupported system ${CMAKE_SYSTEM_NAME:-<unset>}" >&2; exit 1 ;;
    esac
    case "${CMAKE_SYSTEM_PROCESSOR:-}" in
        x86_64)  arch=x86_64 ;;
        aarch64) arch=aarch64 ;;
        riscv64) arch=riscv64 ;;
        *) echo "ffmpeg: unsupported processor ${CMAKE_SYSTEM_PROCESSOR:-<unset>}" >&2; exit 1 ;;
    esac

    # make install also emits the static libraries, headers and presets; a
    # staging prefix keeps those out of out/<target>/tools/. A stale stage is
    # removed so a previous run cannot masquerade as a fresh one.
    local stage="$WORK/stage"
    rm -rf "$stage"

    local args=(
        --prefix="$stage"
        --arch="$arch"
        --target-os="$target_os"
        --enable-cross-compile
        --cc="$CC"
        --cxx="$CXX"
        --ar="$AR"
        --ranlib="$RANLIB"
        --strip="$STRIP"
        --enable-static
        --disable-shared
        --pkg-config-flags=--static
        --enable-gpl
        --enable-version3
        # ffmpeg and ffprobe only.
        --disable-programs
        --enable-ffmpeg
        --enable-ffprobe
        # Docs need texinfo and are not shipped.
        --disable-doc
        # Whatever -dev packages a runner happens to have must not change the
        # binary, and an autodetected shared library would break the static
        # Linux targets.
        --disable-autodetect
    )

    if [[ -n "${CROSS_PREFIX:-}" ]]; then
        args+=(--cross-prefix="$CROSS_PREFIX")
    fi
    # WINDRES is only set for the Windows targets.
    if [[ -n "${WINDRES:-}" ]]; then
        args+=(--windres="$WINDRES")
    fi

    ./configure "${args[@]}"
}

build() {
    cd "$SRC"
    make -j"$(nproc 2>/dev/null || echo 4)"
}

install() {
    cd "$SRC"
    # FFmpeg strips the programs itself with the STRIP passed to configure, so
    # what lands in the staging tree is already what we want to ship.
    make install

    local stage="$WORK/stage"
    local exe="${EXE_SUFFIX:-}"
    mkdir -p "$PREFIX/tools/ffmpeg"

    local prog
    for prog in ffmpeg ffprobe; do
        if [[ ! -f "$stage/bin/$prog$exe" ]]; then
            echo "ffmpeg: expected $stage/bin/$prog$exe after install, found:" >&2
            ls -l "$stage/bin" >&2
            exit 1
        fi
        # cp rather than install(1): install() is this very function.
        cp "$stage/bin/$prog$exe" "$PREFIX/tools/ffmpeg/$prog$exe"
        chmod 755 "$PREFIX/tools/ffmpeg/$prog$exe"
    done
    ls -l "$PREFIX/tools/ffmpeg"
}
