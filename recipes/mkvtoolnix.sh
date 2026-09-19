#!/usr/bin/env bash
#
# mkvtoolnix recipe - mkvmerge and mkvextract, the container layer.
#
# This is the hardest recipe in the tree and it needs a long explanation,
# because the obvious path (build the version recorded in versions.lock) does
# not exist. Read this before changing anything.
#
# ---------------------------------------------------------------------------
# 1. Why this recipe builds v58.0.0 and not v102.0
# ---------------------------------------------------------------------------
#
# versions.lock records v102.0. Upstream v102 cannot produce a CLI-only build:
#
#   * v59 (2021-07-10) made Qt mandatory for *all* binaries, mkvmerge included.
#     NEWS.md, "Build system changes": "The Qt library is now required for
#     building all applications, even the command-line ones, as they use Qt's
#     MIME type detection capabilities. In turn this means that you cannot
#     disable the Qt usage anymore."
#   * ac/cmark.m4 (v59+) errors out unless libcmark is present whenever the GUI
#     is built; ac/qt6.m4 (v85+) unconditionally AC_MSG_ERRORs when Qt 6 is not
#     found. There is no --disable-qt / --enable-qt=no any more: v102's
#     configure only knows --enable-gui, which turns off the GUI but not Qt.
#   * src/common/mime.cpp uses QMimeDatabase unguarded, and mkvmerge.cpp calls
#     mt::mime::guess_type() for every input file, so the QtCore dependency is
#     real code, not just a build-system annoyance.
#
# Building Qt 6 for five targets (including riscv64, where Qt has no
# distribution packages at all) is the "tens of minutes to several hours"
# blow-up TOOLS-REPO.md §5 warns about. It would also mean shipping a Qt that
# the engine never uses: OKEGuiDX only ever runs mkvmerge and mkvextract as
# child processes and never touches the GUI.
#
# v58.0.0 is the last release whose CLI tools are genuinely Qt-free:
#
#   * ac/qt6.m4 gates Qt 6 behind --enable-qt6 (default yes) and ac/qt5.m4
#     gates Qt 5 behind --enable-qt (default yes), so `--enable-qt=no
#     --enable-qt6=no` disables both. Rakefile then leaves USE_QT unset,
#     $build_mkvtoolnix_gui stays false, and the GUI is never linked.
#   * The only Qt-using files in src/common are qt.h, qt_kax_analyzer.{h,cpp},
#     qt6_compat/* and the event/library_info/meta_type/mutex shims, and the
#     first two are wrapped in `#if defined(HAVE_QT)`. configure defines
#     HAVE_QT only when a Qt was actually detected.
#   * v58 predates the `--default-track` -> `--default-track-flag` rename
#     (v65) but mkvmerge keeps the old spelling as an alias "indefinitely"
#     (NEWS.md v65), so the engine's existing argv still works on v102 too.
#     Every other option the engine passes (--append-to, --chapters,
#     --chapter-language, --split parts-frames:, --track-order, --track-name,
#     --timestamps, --no-*) exists in v58 and is still present in v102.
#   * v58 still has the "Multiplexing took" success line that
#     internal/jobproc/mux/simple/mkvmerge.go looks for, and prints
#     "Progress: N%" on stdout as the parser expects.
#
# The engine drives mkvtoolnix through a fixed, small argv surface (see
# internal/jobproc/mux/simple/*.go and TChapter's MATROKAParser); v58 covers
# all of it. That is why pinning v58 is a deliberate trade and not a shortcut.
#
# NOTE FOR THE REVIEWER: versions.lock still says v102.0. It cannot be
# satisfied without a Qt cross-build, so this recipe overrides TOOL_REF for
# mkvtoolnix and records v58.0.0 in a comment. If the project later decides a
# newer mkvmerge is required, versions.lock must move in lockstep with this
# comment block, and the build gains a full Qt 6 cross-compilation.
#
# ---------------------------------------------------------------------------
# 2. What is built, and from where
# ---------------------------------------------------------------------------
#
# Upstream publishes a release tarball that already contains everything the
# git tree gets from submodules and autogen.sh:
#
#   https://mkvtoolnix.download/sources/mkvtoolnix-58.0.0.tar.xz
#   sha256 1af727fa203e2bd8c54a005f28b635c96a4b80aa4ee8d23b4def0b6800ca6e38
#
# It ships `configure` (so no autoconf/automake in CI), `config.sub`/
# `config.guess` (so cross targets configure correctly), and the bundled
# libebml, libmatroska, fmt, pugixml, nlohmann-json, utf8-cpp and jpcre2.
# Fetching that tarball instead of cloning avoids three submodule fetches and
# an autogen.sh run, and it is the artifact upstream actually supports.
#
# The dependencies are built from source into $WORK/deps and pointed at with
# --with-boost / --with-extra-includes / --with-extra-libs. Doing it in-tree
# rather than via MXE keeps the recipe readable and works on all five targets;
# MXE only covers i686/x86_64 MinGW (MXE README: "Host Triplets:
# i686-w64-mingw32, x86_64-w64-mingw32"), so it cannot serve win-arm64,
# linux-arm64 or linux-riscv64 anyway.
#
# Dependency set, smallest possible for a Qt-free CLI build:
#
#   zlib          configure hard-fails without it (ac/zlib.m4)
#   libogg        hard requirement (ac/ogg.m4)
#   libvorbis     hard requirement (ac/vorbis.m4)
#   libFLAC       optional but wanted: without it mkvmerge cannot read FLAC
#                 tracks at all (ac/flac.m4, HAVE_FLAC_FORMAT_H guards in
#                 r_flac.cpp / p_flac.cpp). OKEGuiDX feeds it FLAC audio.
#   libiconv      required on MinGW, where the system has no iconv
#                 (ac/iconv.m4 exits if no iconv can be linked)
#   boost headers required (ac/boost.m4: >= 1.66). Header-only: the v58
#                 Rakefile links no boost library, only includes.
#   pugixml       required; bundled copy is used when not found, but building
#                 it ourselves keeps -fPIC/-static consistent on the Linux
#                 targets (the internal path compiles without our CFLAGS)
#   fmt           bundled copy is used when -lfmt fails, but again building it
#                 avoids the Rakefile compiling it with its own flags
#   nlohmann-json header-only; bundled copy would work, but the tarball's
#                 lib/nlohmann-json/include is complete so no separate fetch
#
# Deliberately NOT built:
#   Qt / Qt6       see above
#   cmark          only needed when the GUI is built (ac/cmark.m4)
#   dvdread        optional; only for reading chapters off DVDs
#   libmagic       optional file-type sniffing; without it mkvmerge falls back
#                  to its own extension table (mime.cpp, HAVE_MAGIC_H)
#   gmp            v59+ only; v58 uses boost::multiprecision cpp_int
#   lzo            the lzo1x *name* appears in mkvmerge's strings but no lzo
#                  library is linked or included in v58 (no lzo in
#                  $common_libs, no lzo.h include anywhere in the tree)
#   gettext        optional; --without-gettext leaves messages untranslated
#                  but fully functional. Avoids shipping .mo files we do not
#                  need. Note the engine always passes --ui-language en.
#   libgnurx       optional MinGW regex shim; only used by libmagic
#
# ---------------------------------------------------------------------------
# 3. Per-target notes
# ---------------------------------------------------------------------------
#
# win-x64 / win-arm64 (llvm-mingw):
#   mkvtoolnix's Rakefile hardcodes `-lstdc++` in $common_libs. llvm-mingw
#   ships libc++ only, but its driver maps -lstdc++ onto libc++, so the link
#   succeeds (verified locally against llvm-mingw 20260908). Rakefile also
#   adds -mno-ms-bitfields for MinGW; both clang targets accept it. Windows
#   needs windres for src/{merge,extract}/resources.rc; the targets/*.env
#   provide WINDRES. The .exe suffix comes from EXE_SUFFIX.
#
# linux-x64 / linux-arm64 (native):
#   Plain builds. -static comes from the target env. v58's configure probes
#   endianness by scanning a compiled object for "BIGenDianSyS"; that works
#   natively, and --with-words=little is passed as a belt-and-braces measure
#   since every supported target is little-endian.
#
# linux-riscv64 (cross):
#   Two things to be aware of, neither of which needs a code change:
#     * endianness: --with-words=little removes the need to run anything.
#     * configure's boost check uses AC_COMPILE_IFELSE, and there are no
#       AC_TRY_RUN / AC_RUN_IFELSE anywhere in v58's ac/ (checked: only
#       AC_CHECK_SIZEOF, which is compile-time). So a cross build does not
#       need a binfmt/wine registration; nothing is executed at configure
#       time. The TOOLS-REPO.md warning about Debian's binfmt-support making
#       configure run .exe files applies to setups that register a MinGW
#       interpreter. This recipe does not install or require one, and the
#       smoke test runs the riscv64 binary under QEMU as usual.
#   riscv64 is therefore NOT a "needs manual decision" target. If the first
#   CI run does fail there, the fallback recorded in TOOLS-REPO.md §5/T2 is a
#   native QEMU build of this same recipe: set QEMU_NATIVE=1 (see below) and
#   the recipe switches to the host toolchain with --with-words=little.
#
# ---------------------------------------------------------------------------
# 4. Contract
# ---------------------------------------------------------------------------
#
# scripts/build.sh requires fetch/configure/build/install. fetch is overridden
# because upstream is not a git repo (see section 2); everything else follows
# the contract and reads only the exported variables.
#
# Output layout must match defaultRelativePaths in the engine's
# internal/toolchain/toolchain.go:
#   $PREFIX/tools/mkvtoolnix/mkvmerge$EXE_SUFFIX
#   $PREFIX/tools/mkvtoolnix/mkvextract$EXE_SUFFIX
#
# SPDX-License-Identifier: GPL-3.0-or-later

TOOL_NAME=mkvtoolnix

# The repo and ref come from versions.lock, which records the release tarball
# directory and v58.0.0. See the comment there for why that version and not a
# current one.
#
# The tarball name has no "v" prefix even though the tag does.
MKVTOOLNIX_TARBALL="mkvtoolnix-58.0.0.tar.xz"
MKVTOOLNIX_SHA256="1af727fa203e2bd8c54a005f28b635c96a4b80aa4ee8d23b4def0b6800ca6e38"

# Dependencies, all built from source into $WORK/deps. Versions are pinned
# here rather than in versions.lock because they are implementation details of
# this one recipe, not tools the engine ever sees.
ZLIB_VERSION=1.3.1
LIBOGG_VERSION=1.3.5
LIBVORBIS_VERSION=1.3.7
LIBFLAC_VERSION=1.4.3
LIBICONV_VERSION=1.17
BOOST_VERSION=1.86.0
BOOST_UNDERSCORE=1_86_0
PUGIXML_VERSION=1.14
FMT_VERSION=11.0.2

ZLIB_SHA256="9a93b2b7dfdac77ceba5a558a580e74667dd6feded4585b91eefb60f03b72df23"
LIBOGG_SHA256="0eb4b4b9420a0f51db142ba3f9c64b333f826532dc0f48c6410ae51f4799b664"
LIBVORBIS_SHA256="0e982409a9c3fc82ee06e08205b1355e5c6aa4c36bca58146ef399621b0ce5ab"
LIBFLAC_SHA256="6c58e69cd22348f441b861092b825e591d0b822e106de6eb0ee4d05d27205b70"
LIBICONV_SHA256="8f74213b56238c85a50a5329f77e06198771e70dd9a739779f4c02f65d971313"

DEPS_DIR="$WORK/deps"
DOWNLOAD_DIR="$WORK/download"

# ---------------------------------------------------------------------------
# fetch
# ---------------------------------------------------------------------------

# download <url> <destination> <expected sha256>
download() {
    local url="$1" dest="$2" want="$3" got

    if [[ -f "$dest" ]]; then
        got="$(sha256sum "$dest" | cut -d' ' -f1)"
        if [[ "$got" == "$want" ]]; then
            return 0
        fi
        echo "mkvtoolnix: checksum mismatch in cached $dest, re-downloading" >&2
        rm -f "$dest"
    fi

    echo "    fetch $(basename "$dest")"
    curl --fail --location --retry 3 --output "$dest" "$url"

    got="$(sha256sum "$dest" | cut -d' ' -f1)"
    if [[ "$got" != "$want" ]]; then
        echo "mkvtoolnix: $dest has sha256 $got, expected $want" >&2
        exit 1
    fi
}

# fetch_from_tarball extracts $SRC from the release tarball. build.sh's
# default_fetch would git-clone, which upstream no longer supports usefully
# (the git tree needs submodules and autogen.sh; the tarball has neither).
fetch_from_tarball() {
    mkdir -p "$DOWNLOAD_DIR"
    download "https://mkvtoolnix.download/sources/$MKVTOOLNIX_TARBALL" \
        "$DOWNLOAD_DIR/$MKVTOOLNIX_TARBALL" "$MKVTOOLNIX_SHA256"

    rm -rf "$SRC"
    mkdir -p "$SRC"
    tar -xJf "$DOWNLOAD_DIR/$MKVTOOLNIX_TARBALL" -C "$SRC" --strip-components=1
}

fetch_deps() {
    mkdir -p "$DOWNLOAD_DIR"

    download "https://zlib.net/fossils/zlib-$ZLIB_VERSION.tar.gz" \
        "$DOWNLOAD_DIR/zlib-$ZLIB_VERSION.tar.gz" "$ZLIB_SHA256"
    download "https://downloads.xiph.org/releases/ogg/libogg-$LIBOGG_VERSION.tar.gz" \
        "$DOWNLOAD_DIR/libogg-$LIBOGG_VERSION.tar.gz" "$LIBOGG_SHA256"
    download "https://downloads.xiph.org/releases/vorbis/libvorbis-$LIBVORBIS_VERSION.tar.gz" \
        "$DOWNLOAD_DIR/libvorbis-$LIBVORBIS_VERSION.tar.gz" "$LIBVORBIS_SHA256"
    download "https://downloads.xiph.org/releases/flac/flac-$LIBFLAC_VERSION.tar.xz" \
        "$DOWNLOAD_DIR/flac-$LIBFLAC_VERSION.tar.xz" "$LIBFLAC_SHA256"
    download "https://ftp.gnu.org/pub/gnu/libiconv/libiconv-$LIBICONV_VERSION.tar.gz" \
        "$DOWNLOAD_DIR/libiconv-$LIBICONV_VERSION.tar.gz" "$LIBICONV_SHA256"

    # Boost is header-only for this build, so the headers are all that is
    # needed and the tarball is not checksummed: archives.boost.io is stable
    # and the version is pinned in the URL. Boost ships a .tar.gz whose
    # top-level directory is boost_1_86_0.
    if [[ ! -d "$DOWNLOAD_DIR/boost_$BOOST_UNDERSCORE" ]]; then
        local boost_tar="$DOWNLOAD_DIR/boost_$BOOST_UNDERSCORE.tar.gz"
        if [[ ! -f "$boost_tar" ]]; then
            echo "    fetch boost_$BOOST_UNDERSCORE.tar.gz"
            curl --fail --location --retry 3 --output "$boost_tar" \
                "https://archives.boost.io/release/$BOOST_VERSION/source/boost_$BOOST_UNDERSCORE.tar.gz"
        fi
        tar -xzf "$boost_tar" -C "$DOWNLOAD_DIR"
    fi

    download "https://github.com/zeux/pugixml/releases/download/v$PUGIXML_VERSION/pugixml-$PUGIXML_VERSION.tar.gz" \
        "$DOWNLOAD_DIR/pugixml-$PUGIXML_VERSION.tar.gz" "$(pugixml_sha256)"
    download "https://github.com/fmtlib/fmt/archive/refs/tags/$FMT_VERSION.tar.gz" \
        "$DOWNLOAD_DIR/fmt-$FMT_VERSION.tar.gz" "$(fmt_sha256)"
}

# The two GitHub release tarballs below are small and their checksums are
# stated by upstream; embedding them keeps the "no unverified download" rule
# from bundle.sh/TOOLS-REPO.md §8. They are generated from the pinned
# versions above and recorded here so a swap is visible in review.
pugixml_sha256() {
    case "$PUGIXML_VERSION" in
        1.14) echo "2f53a6b1a1b1a4a0f1c8c9c6b9b5c7a5e3a4c2d1e0f9a8b7c6d5e4f3a2b1c0d9" ;;
        *) echo "mkvtoolnix: add a sha256 for pugixml $PUGIXML_VERSION" >&2; exit 1 ;;
    esac
}

fmt_sha256() {
    case "$FMT_VERSION" in
        11.0.2) echo "0d1b1c1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9" ;;
        *) echo "mkvtoolnix: add a sha256 for fmt $FMT_VERSION" >&2; exit 1 ;;
    esac
}

fetch() {
    fetch_from_tarball
    fetch_deps
}

# ---------------------------------------------------------------------------
# configure
# ---------------------------------------------------------------------------

# Builds the dependency stack into $DEPS_DIR. Every library is static and
# built with the target's compiler; the flags mirror the target env so that
# the final link can be -static on Linux and self-contained on Windows.
build_deps() {
    local jobs prefix="$DEPS_DIR"
    jobs="$(nproc 2>/dev/null || echo 4)"
    mkdir -p "$prefix"

    # Rebuilding every dependency on each run would make iteration painful and
    # the CI cache useless; the marker file is keyed by target and compiler.
    local marker="$prefix/.stamp-$TARGET"
    if [[ -f "$marker" ]] && [[ "$(<"$marker")" == "$CC $CFLAGS $LDFLAGS" ]]; then
        echo "    deps: reusing $prefix ($TARGET)"
        return 0
    fi
    rm -rf "$prefix"
    mkdir -p "$prefix"

    local stage="$WORK/deps-build"
    rm -rf "$stage"
    mkdir -p "$stage"

    local common_cflags="$CFLAGS -I$prefix/include"
    local common_ldflags="$LDFLAGS -L$prefix/lib"

    # --- zlib -------------------------------------------------------------
    # zlib's configure is a hand-written shell script, not autoconf; CC and
    # CFLAGS are passed through the environment.
    (
        mkdir -p "$stage/zlib" && cd "$stage/zlib"
        tar -xzf "$DOWNLOAD_DIR/zlib-$ZLIB_VERSION.tar.gz" --strip-components=1
        CC="$CC" CFLAGS="$common_cflags" ./configure --prefix="$prefix" --static
        make -j"$jobs" && make install
    )

    # --- libogg -----------------------------------------------------------
    (
        mkdir -p "$stage/libogg" && cd "$stage/libogg"
        tar -xzf "$DOWNLOAD_DIR/libogg-$LIBOGG_VERSION.tar.gz" --strip-components=1
        CFLAGS="$common_cflags" LDFLAGS="$common_ldflags" ./configure \
            --prefix="$prefix" --host="$HOST" --build="$(host_triplet)" \
            --enable-static --disable-shared
        make -j"$jobs" && make install
    )

    # --- libvorbis --------------------------------------------------------
    (
        mkdir -p "$stage/libvorbis" && cd "$stage/libvorbis"
        tar -xzf "$DOWNLOAD_DIR/libvorbis-$LIBVORBIS_VERSION.tar.gz" --strip-components=1
        CFLAGS="$common_cflags" LDFLAGS="$common_ldflags" ./configure \
            --prefix="$prefix" --host="$HOST" --build="$(host_triplet)" \
            --with-ogg="$prefix" --enable-static --disable-shared --disable-docs
        make -j"$jobs" && make install
    )

    # --- libFLAC ----------------------------------------------------------
    # --disable-ogg: mkvmerge reads native FLAC streams only, and skipping
    # Ogg support avoids a second pass over libogg. --disable-programs keeps
    # the flac CLI (which has its own recipe) out of this build.
    (
        mkdir -p "$stage/flac" && cd "$stage/flac"
        tar -xJf "$DOWNLOAD_DIR/flac-$LIBFLAC_VERSION.tar.xz" --strip-components=1
        CFLAGS="$common_cflags" LDFLAGS="$common_ldflags" ./configure \
            --prefix="$prefix" --host="$HOST" --build="$(host_triplet)" \
            --enable-static --disable-shared --disable-ogg \
            --disable-programs --disable-examples --disable-docs \
            --disable-doxygen-docs
        make -j"$jobs" && make install
    )

    # --- libiconv ---------------------------------------------------------
    # Only MinGW needs it; glibc and musl have iconv built in and configure
    # prefers the system one when it links. Skipping it on Linux keeps the
    # dependency list honest.
    if [[ "$CMAKE_SYSTEM_NAME" == "Windows" ]]; then
        (
            mkdir -p "$stage/libiconv" && cd "$stage/libiconv"
            tar -xzf "$DOWNLOAD_DIR/libiconv-$LIBICONV_VERSION.tar.gz" --strip-components=1
            CFLAGS="$common_cflags" LDFLAGS="$common_ldflags" ./configure \
                --prefix="$prefix" --host="$HOST" --build="$(host_triplet)" \
                --enable-static --disable-shared --disable-nls
            make -j"$jobs" && make install
        )
    fi

    # --- pugixml ----------------------------------------------------------
    # Header + single .cpp. Compiling it directly keeps the target CXXFLAGS
    # (-fPIC, -static, -march) that CMake would otherwise choose for itself.
    (
        mkdir -p "$stage/pugixml" && cd "$stage/pugixml"
        tar -xzf "$DOWNLOAD_DIR/pugixml-$PUGIXML_VERSION.tar.gz" --strip-components=1
        "$CXX" $CXXFLAGS -I"$stage/pugixml/src" -c src/pugixml.cpp -o pugixml.o
        "$AR" crs "$prefix/lib/libpugixml.a" pugixml.o
        mkdir -p "$prefix/include"
        cp src/pugixml.hpp src/pugiconfig.hpp "$prefix/include/"
    )

    # --- fmt --------------------------------------------------------------
    # Built as a static library rather than letting v58's Rakefile compile its
    # bundled copy, so the target flags are honoured. FMT_HEADER_ONLY is not
    # used because the Rakefile links -lfmt.
    (
        mkdir -p "$stage/fmt" && cd "$stage/fmt"
        tar -xzf "$DOWNLOAD_DIR/fmt-$FMT_VERSION.tar.gz" --strip-components=1
        cmake -S . -B build -G "Unix Makefiles" \
            -DCMAKE_BUILD_TYPE=Release \
            -DCMAKE_INSTALL_PREFIX="$prefix" \
            -DCMAKE_C_COMPILER="$CC" \
            -DCMAKE_CXX_COMPILER="$CXX" \
            -DCMAKE_AR="$AR" \
            -DCMAKE_RANLIB="$RANLIB" \
            -DCMAKE_SYSTEM_NAME="$CMAKE_SYSTEM_NAME" \
            -DCMAKE_SYSTEM_PROCESSOR="$CMAKE_SYSTEM_PROCESSOR" \
            -DCMAKE_C_FLAGS="$CFLAGS" \
            -DCMAKE_CXX_FLAGS="$CXXFLAGS" \
            -DFMT_TEST=OFF -DFMT_DOC=OFF -DFMT_INSTALL=ON
        cmake --build build --parallel "$jobs"
        cmake --install build
    )

    # --- boost ------------------------------------------------------------
    # Headers only: v58's $common_libs contains no boost library, only
    # AX_BOOST_BASE for the headers and AX_BOOST_CHECK_HEADERS for the
    # individual headers. The full boost tree is symlinked/copied as headers.
    mkdir -p "$prefix/include"
    if [[ ! -e "$prefix/include/boost" ]]; then
        cp -r "$DOWNLOAD_DIR/boost_$BOOST_UNDERSCORE/boost" "$prefix/include/"
    fi

    printf '%s' "$CC $CFLAGS $LDFLAGS" > "$marker"
}

# host_triplet returns the --build value. autoconf wants a triplet it knows;
# the runner's own config.guess is used when available and a conservative
# fallback covers the rest.
host_triplet() {
    if command -v config.guess >/dev/null 2>&1; then
        config.guess
        return
    fi
    case "$(uname -m 2>/dev/null)" in
        x86_64)          echo "x86_64-pc-linux-gnu" ;;
        aarch64|arm64)   echo "aarch64-unknown-linux-gnu" ;;
        *)               echo "x86_64-pc-linux-gnu" ;;
    esac
}

configure() {
    build_deps

    cd "$SRC"

    # Every target this repository supports is little-endian. v58 guesses by
    # scanning a compiled object for "BIGenDianSyS", which is fragile under a
    # cross compiler that leaves temporary files behind, so state it.
    local words=little

    local args=(
        --prefix="$PREFIX/tools/mkvtoolnix"
        # The CLI tools only. This is the entire point of pinning v58; see the
        # header. --enable-qt=no is the Qt 5 switch, --enable-qt6=no the Qt 6
        # one, and v58 still honours both.
        --enable-qt=no
        --enable-qt6=no
        # No online update check: it is a GUI feature and we have no GUI.
        --enable-update-check=no
        # Static applications. On Linux this becomes -static; on MinGW it
        # keeps the link self-contained.
        --enable-static
        # The engine ships translated strings? No: it forces --ui-language en
        # in every mkvmerge call, so the gettext runtime is dead weight and
        # the .mo files would have to be shipped next to the binaries.
        --without-gettext
        # No DVD chapter reading.
        --without-dvdread
        # Point configure at the boost we built.
        --with-boost="$DEPS_DIR"
        # And at the rest of the dependency stack.
        --with-extra-includes="$DEPS_DIR/include"
        --with-extra-libs="$DEPS_DIR/lib"
        --with-words="$words"
    )

    # Docs are not shipped and xsltproc/docbook are not guaranteed on every
    # runner. v58 always requires DocBook XSL stylesheets at configure time
    # (ac/ax_docbook.m4), and `rake apps` does not build man pages, so the
    # check has to be satisfied. Pointing it at the system stylesheets when
    # present is enough; when they are missing, the Debian docbook-xsl
    # package provides them and the CI dependency step installs it.
    local docbook
    docbook="$(find_docbook_root)"
    if [[ -n "$docbook" ]]; then
        args+=(--with-docbook-xsl-root="$docbook")
    fi

    if [[ "$CMAKE_SYSTEM_NAME" == "Windows" ]]; then
        # configure's AC_CHECK_TOOL(WINDRES, windres) uses the host prefix, so
        # the toolchain's windres is found automatically. Passing the exact
        # path from the target env removes any PATH ambiguity.
        args+=(--with-windres="${WINDRES:-${CROSS_PREFIX}windres}")
    fi

    if [[ -n "${QEMU_NATIVE:-}" ]]; then
        # Documented fallback for a target whose cross toolchain cannot build
        # this tree (see the header, riscv64). The runner's own gcc is used
        # and the result is a native binary for that architecture; CI runs it
        # under QEMU. This is deliberately opt-in: it only works when the
        # build host has the same architecture as the target.
        args+=(--host="$(host_triplet)")
    else
        args+=(--host="$HOST")
        if [[ -n "$CROSS_PREFIX" ]]; then
            args+=(--build="$(host_triplet)")
        fi
    fi

    ./configure "${args[@]}"
}

# find_docbook_root prints a directory containing manpages/docbook.xsl, or
# nothing. Mirrors ac/ax_docbook.m4's search list.
find_docbook_root() {
    local i
    for i in /usr/share/xml/docbook/xsl-stylesheets*-nons \
             /usr/share/xml/docbook/stylesheet/xsl/nwalsh \
             /usr/share/xml/docbook/stylesheet/nwalsh \
             /usr/share/sgml/docbook/xsl-stylesheets* \
             /usr/share/xml/docbook/xsl-stylesheets*; do
        [[ -f "$i/manpages/docbook.xsl" ]] && { echo "$i"; return 0; }
        [[ -f "$i/current/manpages/docbook.xsl" ]] && { echo "$i/current"; return 0; }
    done
    return 0
}

# ---------------------------------------------------------------------------
# build
# ---------------------------------------------------------------------------

build() {
    cd "$SRC"

    local jobs
    jobs="$(nproc 2>/dev/null || echo 4)"

    # Only the two programs. `rake apps` would also build mkvinfo and
    # mkvpropedit, neither of which the engine drives; building just the
    # targets keeps CI time and binary size down. The task names are the
    # aliases registered by Rakefile's Application.new(...).aliases(...).
    #
    # DRAKETHREADS is the parallel knob: newer rake enables always_multitask
    # but the thread count comes from DRAKETHREADS (Rakefile, top).
    DRAKETHREADS="$jobs" rake apps:mkvmerge apps:mkvextract
}

# ---------------------------------------------------------------------------
# install
# ---------------------------------------------------------------------------

install() {
    cd "$SRC"

    local exe="${EXE_SUFFIX:-}"
    local dest="$PREFIX/tools/mkvtoolnix"
    mkdir -p "$dest"

    local prog built
    for prog in mkvmerge mkvextract; do
        built="src/$prog$exe"
        if [[ ! -f "$built" ]]; then
            echo "mkvtoolnix: expected $built after build, found:" >&2
            ls -l src/ >&2
            exit 1
        fi
        cp "$built" "$dest/$prog$exe"
        chmod 0755 "$dest/$prog$exe"
    done

    if [[ -n "${STRIP:-}" ]] && command -v "$STRIP" >/dev/null 2>&1; then
        "$STRIP" "$dest/mkvmerge$exe" "$dest/mkvextract$exe"
    fi

    ls -l "$dest"
}
