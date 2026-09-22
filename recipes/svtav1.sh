#!/usr/bin/env bash
#
# SVT-AV1 recipe - CMake build of the AV1 encoder application (TOOLS-REPO.md §5).
#
# SVT-AV1 probes the compiler at configure time and picks its SIMD backend from
# the result: x86 assembles NASM kernels, AArch64 compiles NEON (plus
# CRC32/DotProd/I8MM/SVE when the compiler accepts the flags), and every other
# architecture - RISC-V included - falls back to plain C. The target is
# therefore described completely by CMAKE_SYSTEM_NAME, CMAKE_SYSTEM_PROCESSOR
# and the compiler variables that targets/<target>.env already exports, so no
# toolchain file is needed. CFLAGS/CXXFLAGS/LDFLAGS from that same file are
# picked up by CMake through the environment, which is where it takes its
# initial flag values from.
#
# The result is one static binary, installed where the engine's toolchain layer
# looks for it: tools/svtav1/SvtAv1EncApp[.exe]
# (internal/toolchain/toolchain.go, defaultRelativePaths).
#
# SPDX-License-Identifier: GPL-3.0-or-later

TOOL_NAME=svtav1

# Paths are derived inside the functions: build.sh sources the recipe before it
# exports WORK, and `set -u` would reject a top-level reference.

# nproc is missing on some minimal images; fall back to a conservative number.
JOBS="$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"

configure() {
    local build="$WORK/build"
    rm -rf "$build" "$WORK/stage"
    mkdir -p "$build"

    local -a opts=(
        -DCMAKE_BUILD_TYPE=Release
        # The install is staged: SVT-AV1 would otherwise drop its static
        # library, headers, pkg-config and CMake package files into the prefix,
        # and the bundle only needs the encoder binary.
        -DCMAKE_INSTALL_PREFIX="$WORK/stage"
        -DCMAKE_C_COMPILER="$CC"
        -DCMAKE_CXX_COMPILER="$CXX"
        -DCMAKE_AR="$AR"
        -DCMAKE_RANLIB="$RANLIB"
        # Static library, so the Windows binary carries no DLL beside it and
        # the Linux one has nothing to resolve at run time.
        -DBUILD_SHARED_LIBS=OFF
        # Only the encoder application is used by the engine.
        -DBUILD_APPS=ON
        -DBUILD_TESTING=OFF
        # SVT_AV1_LTO defaults to ON for GCC >= 9 / Clang >= 12. It is the
        # slowest and least predictable part of a cross build, and it buys
        # little for an encoder that is already fully vectorised, so it is off.
        -DSVT_AV1_LTO=OFF
    )

    # Only cross builds need these; a native build must not be told it is
    # cross-compiling.
    if [[ -n "${CMAKE_SYSTEM_NAME:-}" ]]; then
        opts+=(-DCMAKE_SYSTEM_NAME="$CMAKE_SYSTEM_NAME")
    fi
    if [[ -n "${CMAKE_SYSTEM_PROCESSOR:-}" ]]; then
        opts+=(-DCMAKE_SYSTEM_PROCESSOR="$CMAKE_SYSTEM_PROCESSOR")
    fi

    case "${CMAKE_SYSTEM_PROCESSOR:-}" in
        x86_64|amd64|AMD64)
            # The x86 kernels are NASM. Without an assembler CMake silently
            # falls back to the plain C path, which is many times slower, so
            # check up front and fail loudly when neither is available. The
            # bare name is passed on purpose: CMake resolves it itself, which
            # also appends the .exe suffix on Windows, where `command -v`
            # returns a path without one.
            if ! command -v nasm >/dev/null 2>&1 && ! command -v yasm >/dev/null 2>&1; then
                echo "svtav1: nasm (or yasm) is required for $TARGET but was not found in PATH" >&2
                exit 1
            fi
            if command -v nasm >/dev/null 2>&1; then
                opts+=(-DCMAKE_ASM_NASM_COMPILER=nasm)
            else
                opts+=(-DCMAKE_ASM_NASM_COMPILER=yasm)
            fi
            ;;
        riscv64)
            # Upstream has no RISC-V vector backend, so this is a pure C build;
            # saying so skips the x86/AArch64 assembler probes.
            opts+=(-DCOMPILE_C_ONLY=ON)
            ;;
    esac

    cmake -S "$SRC" -B "$build" "${opts[@]}"
}

build() {
    cmake --build "$WORK/build" --parallel "$JOBS"
}

install() {
    cmake --build "$WORK/build" --target install --parallel "$JOBS"

    mkdir -p "$PREFIX/tools/svtav1"
    # cp rather than install(1): this function is itself named install and
    # shadows the command.
    cp -f "$WORK/stage/bin/SvtAv1EncApp${EXE_SUFFIX:-}" "$PREFIX/tools/svtav1/"
    chmod 0755 "$PREFIX/tools/svtav1/SvtAv1EncApp${EXE_SUFFIX:-}"
    ls -l "$PREFIX/tools/svtav1"
}
