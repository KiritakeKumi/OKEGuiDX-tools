#!/usr/bin/env bash
#
# x265 recipe - the three flavours OKEGuiDX can drive, each one a merged
# 8/10/12-bit binary.
#
# A libx265 stores pixels at one internal depth only. The supported way to ship
# a single binary that accepts --output-depth 8, 10 and 12 is upstream's
# multilib build (build/linux/multilib.sh), which this recipe follows:
#
#   12bit  HIGH_BIT_DEPTH=ON + MAIN12=ON, EXPORT_C_API=OFF  -> libx265.a
#   10bit  HIGH_BIT_DEPTH=ON,             EXPORT_C_API=OFF  -> libx265.a
#    8bit  EXTRA_LIB=<the two above>, LINKED_10BIT + LINKED_12BIT
#          The 8-bit library becomes the front end: its x265_api_get() calls
#          into the x265_10bit / x265_12bit namespaces, and the CLI, which
#          links x265-static, ends up carrying all three depths. The 10/12-bit
#          archives reach the linker as -lx265_main10 / -lx265_main12 through
#          -DEXTRA_LINK_FLAGS=-L., exactly as multilib.sh arranges them.
#
# Only the CLI from the 8-bit tree is installed. The combined libx265.a that
# multilib.sh additionally produces is a library-user artefact; the bundle
# ships executables only.
#
# Flavour differences (versions.lock holds the repository and ref of each):
#   upstream  multicoreware 4.x, the default on every target except win-x64
#   asuna     msg7086's Yuuki-Asuna fork, frozen at the 3.5 baseline
#   kyouko    AmusementClub's fork, upstream 4.1 plus x86 tuning
#
# Two small patches in patches/ fix the forks for this configuration:
#
#   x265-kyouko-cxx11.patch     Kyouko's CMakeLists selects -std=gnu++98
#                               whenever HDR10+ and AviSynth are off, but its
#                               own CLI uses C++11 range-based for loops. Its
#                               CI never hits that branch because it enables
#                               HDR10+; this recipe deliberately does not.
#   x265-asuna-register.patch   Asuna builds as C++17, where clang rejects the
#                               'register' storage class in common/md5.cpp.
#
# build.sh reuses work/<target>/<recipe>-<variant>/src between runs and
# re-checks out the ref every time, so the patches are applied from a clean
# tree; the already-applied check keeps a manually patched tree from erroring.
#
# CMake options below, checked against each variant's source/CMakeLists.txt:
#
#   HIGH_BIT_DEPTH, MAIN12     select the depth of one library build
#   EXPORT_C_API=OFF           keeps the C API out of the 10/12-bit libraries,
#                              whose entry points stay in the x265_10bit and
#                              x265_12bit namespaces
#   EXTRA_LIB, EXTRA_LINK_FLAGS, LINKED_10BIT, LINKED_12BIT
#                              the multilib wiring described above
#   ENABLE_SHARED=OFF          the CLI links x265-static, so the bundle holds
#                              one self-contained executable and no .so/.dll
#   ENABLE_LIBNUMA=OFF         never take a libnuma runtime dependency, which
#                              a -static link could not resolve anyway
#   ENABLE_HDR10_PLUS=OFF      OKEGuiDX never passes --dhdr10-info, so the
#                              dynamicHDR10 sources stay out of the build
#   ENABLE_AVISYNTH=OFF, ENABLE_VPYSYNTH=OFF,
#   ENABLE_LSMASH=OFF, ENABLE_MKV=OFF, ENABLE_LAVF=OFF, ENABLE_ZIMG=OFF
#                              the forks default some of these ON and probe for
#                              the libraries. OKEGuiDX pipes y4m through stdin,
#                              so none of them may be enabled.
#   TARGET_CPU=x86-64          Kyouko's CMakeLists defaults it to "generic",
#                              which GCC and clang reject as a -march= value
#   CMAKE_POLICY_VERSION_MINIMUM=3.5
#                              all three trees require CMake 2.8.8, which
#                              CMake 4.x refuses without this escape hatch.
#                              It does not cover the separate
#                              cmake_policy(SET ... OLD) calls, which CMake 4
#                              also rejects; the CI runners ship CMake 3.x
#                              (Ubuntu 24.04 has 3.28, Alpine 3.20 has 3.29).
#
# SPDX-License-Identifier: GPL-3.0-or-later

TOOL_NAME=x265

# build.sh looks TOOL_REPO/TOOL_REF up in versions.lock by variant, so an empty
# variant has to become the platform default before that lookup happens. The
# default is upstream everywhere except win-x64 (TOOLS-REPO.md §3, README.md).
TOOL_VARIANT="${VARIANT:-upstream}"

# Filled by collect_common_flags(); read by configure().
COMMON_FLAGS=()

collect_common_flags() {
    COMMON_FLAGS=(
        -DCMAKE_BUILD_TYPE=Release
        -DCMAKE_SYSTEM_NAME="$CMAKE_SYSTEM_NAME"
        -DCMAKE_SYSTEM_PROCESSOR="$CMAKE_SYSTEM_PROCESSOR"
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5
        -DENABLE_SHARED=OFF
        -DENABLE_HDR10_PLUS=OFF
        -DENABLE_TESTS=OFF
    )
    # libnuma only exists for UNIX, so asking for it on Windows would just be
    # reported as an unused variable.
    if [[ "$CMAKE_SYSTEM_NAME" != Windows ]]; then
        COMMON_FLAGS+=(-DENABLE_LIBNUMA=OFF)
    fi
    case "$TOOL_VARIANT" in
        asuna|kyouko)
            COMMON_FLAGS+=(
                -DENABLE_AVISYNTH=OFF
                -DENABLE_VPYSYNTH=OFF
                -DENABLE_LSMASH=OFF
                -DENABLE_MKV=OFF
                -DENABLE_LAVF=OFF
                -DENABLE_ZIMG=OFF
            )
            ;;
    esac
    if [[ "$TOOL_VARIANT" == kyouko ]]; then
        case "$CMAKE_SYSTEM_PROCESSOR" in
            x86_64|amd64|x86|i386|i686)
                # Kyouko defaults TARGET_CPU to "generic", which GCC and clang
                # reject as a -march= value, so its own CI always overrides it.
                # x86-64 is the most conservative value in that matrix; runtime
                # CPU detection still selects the SIMD kernels of the host.
                COMMON_FLAGS+=(-DTARGET_CPU=x86-64)
                ;;
        esac
    fi
    # CMake does not read the exported WINDRES variable on its own. Passing it
    # explicitly keeps the UTF-8 manifest in the Windows binaries; if the
    # resource compiler is missing the build still succeeds without it.
    if [[ -n "${WINDRES:-}" ]] && command -v "$WINDRES" >/dev/null 2>&1; then
        COMMON_FLAGS+=(-DCMAKE_RC_COMPILER="$WINDRES")
    fi
}

# cmake_configure <build dir> <extra cmake args...>
cmake_configure() {
    local dir="$1"
    shift
    mkdir -p "$dir"
    cmake -S "$SRC/source" -B "$dir" "${COMMON_FLAGS[@]}" "$@"
}

# default_fetch checks out the pinned ref, so the patch is applied from a clean
# tree; the already-applied check keeps a manually patched tree from erroring.
apply_patches() {
    local patch
    case "$TOOL_VARIANT" in
        kyouko) patch="$ROOT/patches/x265-kyouko-cxx11.patch" ;;
        asuna)  patch="$ROOT/patches/x265-asuna-register.patch" ;;
        *)      return 0 ;;
    esac
    [[ -f "$patch" ]] || { echo "missing patch: $patch" >&2; return 1; }
    if git -C "$SRC" apply --reverse --check "$patch" >/dev/null 2>&1; then
        echo "    patch already applied: $(basename "$patch")"
        return 0
    fi
    git -C "$SRC" apply --verbose "$patch"
}

fetch() {
    default_fetch
    apply_patches
}

configure() {
    collect_common_flags

    # build.sh checks the ref out into the same $SRC on every run, so a stale
    # build directory would otherwise survive a version bump.
    rm -rf "${WORK:?}/build"

    # All three trees are generated up front. The archives the front-end link
    # needs do not exist yet: CMake only records the bare names in EXTRA_LIB,
    # and the linker resolves them through -DEXTRA_LINK_FLAGS=-L. when the
    # front-end target is built (build()).
    #
    # The front end is 8-bit, following upstream's multilib.sh, except for
    # Kyouko. AmusementClub's own CI makes the 10-bit pass the front end, so
    # their released binary defaults to --output-depth 10; using an 8-bit front
    # end here would silently change the depth of any profile that omits -D.
    # PLAN.md requires win-x64 to preserve existing encoding behaviour, so the
    # Kyouko build follows its upstream.
    if [[ "$TOOL_VARIANT" == kyouko ]]; then
        cmake_configure "$WORK/build/12bit" \
            -DHIGH_BIT_DEPTH=ON -DMAIN12=ON -DEXPORT_C_API=OFF -DENABLE_CLI=OFF
        cmake_configure "$WORK/build/8bit" \
            -DHIGH_BIT_DEPTH=OFF -DEXPORT_C_API=OFF -DENABLE_CLI=OFF
        cmake_configure "$WORK/build/10bit" \
            -DEXTRA_LIB="x265_main.a;x265_main12.a" \
            -DEXTRA_LINK_FLAGS=-L. \
            -DLINKED_8BIT=ON -DLINKED_12BIT=ON
    else
        cmake_configure "$WORK/build/12bit" \
            -DHIGH_BIT_DEPTH=ON -DMAIN12=ON -DEXPORT_C_API=OFF -DENABLE_CLI=OFF
        cmake_configure "$WORK/build/10bit" \
            -DHIGH_BIT_DEPTH=ON -DEXPORT_C_API=OFF -DENABLE_CLI=OFF
        cmake_configure "$WORK/build/8bit" \
            -DEXTRA_LIB="x265_main10.a;x265_main12.a" \
            -DEXTRA_LINK_FLAGS=-L. \
            -DLINKED_10BIT=ON -DLINKED_12BIT=ON
    fi
}

build() {
    local jobs
    jobs="$(nproc 2>/dev/null || echo 4)"

    if [[ "$TOOL_VARIANT" == kyouko ]]; then
        # The 8-bit and 12-bit libraries are linked into the 10-bit front end.
        cmake --build "$WORK/build/12bit" --parallel "$jobs"
        cmake --build "$WORK/build/8bit" --parallel "$jobs"
        cp "$WORK/build/8bit/libx265.a" "$WORK/build/10bit/libx265_main.a"
        cp "$WORK/build/12bit/libx265.a" "$WORK/build/10bit/libx265_main12.a"
        cmake --build "$WORK/build/10bit" --parallel "$jobs"
        return
    fi

    # The high-bit-depth libraries come first: the 8-bit front end links them.
    cmake --build "$WORK/build/12bit" --parallel "$jobs"
    cmake --build "$WORK/build/10bit" --parallel "$jobs"

    # The archives must carry the names EXTRA_LIB refers to inside the 8-bit
    # build directory, and be reachable through -L.. multilib.sh symlinks
    # them; a copy works everywhere and avoids relative-link surprises.
    cp "$WORK/build/10bit/libx265.a" "$WORK/build/8bit/libx265_main10.a"
    cp "$WORK/build/12bit/libx265.a" "$WORK/build/8bit/libx265_main12.a"

    cmake --build "$WORK/build/8bit" --parallel "$jobs"
}

install() {
    local exe="${EXE_SUFFIX:-}"
    local name
    # Must match x265FileName() in the engine's internal/toolchain/toolchain.go.
    case "$TOOL_VARIANT" in
        asuna)  name="x265-asuna" ;;
        kyouko) name="x265-kyouko" ;;
        *)      name="x265" ;;
    esac

    # The Kyouko build puts its front end in the 10-bit tree; the other variants
    # use the 8-bit tree. See configure() for why they differ.
    local frontend="8bit"
    [[ "$TOOL_VARIANT" == kyouko ]] && frontend="10bit"
    local built="$WORK/build/$frontend/x265$exe"
    [[ -f "$built" ]] || { echo "x265: $built was not built" >&2; exit 1; }

    local dest="$PREFIX/tools/x26x"
    mkdir -p "$dest"
    cp "$built" "$dest/$name$exe"
    chmod 0755 "$dest/$name$exe"

    # The link would already have failed if the extra archives were missing,
    # but a single-depth binary is the failure mode this recipe exists to
    # avoid, so assert it. version.cpp builds the report string from
    # BITDEPTH ADD8 ADD10 ADD12, and LINKED_* are what turn the extras into
    # "+10bit+12bit"; a single-depth build reads e.g. "8bit" alone.
    # grepping the file avoids a pipeline, which `set -o pipefail` from
    # build.sh would turn into a false failure once grep -q exits early.
    #
    # The reported depth differs by front end: the 8-bit one reads
    # "8bit+10bit+12bit", the 10-bit one "10bit+8bit+12bit".
    local marker="8bit+10bit+12bit"
    [[ "$frontend" == "10bit" ]] && marker="10bit+8bit+12bit"
    if ! grep -qaF "$marker" "$dest/$name$exe"; then
        echo "x265: $name$exe is not a merged 8/10/12-bit build (want $marker)" >&2
        exit 1
    fi

    if [[ -n "${STRIP:-}" ]] && command -v "$STRIP" >/dev/null 2>&1; then
        "$STRIP" "$dest/$name$exe"
    fi

    ls -l "$dest"
}
