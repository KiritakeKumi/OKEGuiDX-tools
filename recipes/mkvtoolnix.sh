#!/usr/bin/env bash
#
# mkvtoolnix recipe - mkvmerge and mkvextract, the container layer.
#
# This is the hardest recipe in the tree, and the version that versions.lock
# names cannot be built the way the other recipes are. Read this header before
# changing anything; the reasoning is the whole reason this file is long.
#
# ---------------------------------------------------------------------------
# 1. Why this recipe builds 58.0.0 and not 102.0
# ---------------------------------------------------------------------------
#
# versions.lock records v102.0. Upstream 102.0 cannot produce a CLI-only
# build, and the engine only ever needs the two CLI programs:
#
#   * 59.0.0 (2021-07-10) made Qt mandatory for every binary, mkvmerge
#     included. Its NEWS.md, "Build system changes", states it outright: "The
#     Qt library is now required for building all applications, even the
#     command-line ones, as they use Qt's MIME type detection capabilities. In
#     turn this means that you cannot disable the Qt usage anymore."
#   * From 85.0 onwards ac/qt6.m4 unconditionally fails with "The Qt library
#     version >= ... is required for building MKVToolNix." There is no
#     --disable-qt any more; --enable-gui only drops the GUI. 102.0 has only
#     ac/qt6.m4 and no ac/qt5.m4 at all.
#   * src/common/mime.cpp in 59.0+ uses QMimeDatabase with no #if guard, and
#     mkvmerge.cpp calls mtx::mime::guess_type() on every input file, so the
#     QtCore dependency is real code, not a configure quirk.
#
# Cross-compiling Qt 6 for five targets - including riscv64, which has no Qt
# packages on any distribution - is the "tens of minutes becomes hours"
# blow-up TOOLS-REPO.md §5 warns about. It would also ship a Qt the engine
# never touches: OKEGuiDX drives mkvmerge/mkvextract as child processes only.
#
# 58.0.0 is the last release whose CLI tools are genuinely Qt-free:
#
#   * ac/qt6.m4 gates Qt 6 behind --enable-qt6 (default yes) and ac/qt5.m4
#     gates Qt 5 behind --enable-qt (default yes), so --enable-qt=no
#     --enable-qt6=no disables both. Rakefile then leaves USE_QT unset,
#     $build_mkvtoolnix_gui stays false, and no Qt code is linked.
#   * The only Qt-using files in src/common are qt.h, qt_kax_analyzer.{h,cpp},
#     qt6_compat/* and the event/library_info/meta_type/mutex shims. The first
#     two are wrapped in `#if defined(HAVE_QT)`, which configure only defines
#     when a Qt was found. `--enable-qt=no --enable-qt6=no` compiles them away.
#   * 58.0.0 predates the --default-track -> --default-track-flag rename (65.0)
#     but mkvmerge keeps the old spelling as an alias "indefinitely" (65.0
#     NEWS), and 102.0 still accepts --default-track in its argument parser, so
#     the engine's argv works on both. Every other option the engine passes
#     exists in 58.0: --append-to, --chapters, --chapter-language, --split
#     parts-frames:, --track-order, --track-name, --timestamps, --no-*.
#     (Verified against doc/man/mkvmerge.xml in the 58.0.0 tarball.)
#   * 58.0.0 prints the "Multiplexing took" success line that
#     internal/jobproc/mux/simple/mkvmerge.go keys on, and "Progress: N%" on
#     stdout exactly as its parser expects.
#
# The engine's mkvmerge surface is fixed and small (see
# internal/jobproc/mux/simple/*.go and TChapter's MATROKAParser); 58.0.0
# covers all of it. Pinning 58.0.0 is therefore a deliberate trade, not a
# shortcut.
#
# ACTION REQUIRED (human decision, recorded in the C6 report): versions.lock
# still says v102.0. This recipe overrides TOOL_REF because the locked version
# cannot be satisfied without a Qt cross-build. Either versions.lock moves to
# 58.0.0 (recommended - keeps the single source of truth honest) or the
# project accepts a Qt 6 cross-build and this header gets rewritten. Until
# then the two disagree, which is exactly the kind of thing the lock file
# exists to prevent.
#
# ---------------------------------------------------------------------------
# 2. What is built, and from where
# ---------------------------------------------------------------------------
#
# Upstream publishes a release tarball that already contains what the git tree
# gets from submodules plus autogen.sh:
#
#   https://mkvtoolnix.download/sources/mkvtoolnix-58.0.0.tar.xz
#   sha256 1af727fa203e2bd8c54a005f28b635c96a4b80aa4ee8d23b4def0b6800ca6e38
#
# It ships `configure` (no autoconf/automake in CI), config.sub/config.guess
# (cross targets configure correctly), and bundled libebml, libmatroska, fmt,
# pugixml, nlohmann-json, utf8-cpp and jpcre2. Using it avoids three submodule
# fetches and an autogen.sh run, and it is the artefact upstream supports.
#
# Dependencies, built from source into $WORK/deps:
#
#   zlib          configure hard-fails without it (ac/zlib.m4)
#   libogg        hard requirement (ac/ogg.m4)
#   libvorbis     hard requirement (ac/vorbis.m4)
#   libFLAC       wanted: without it mkvmerge cannot read FLAC tracks at all
#                 (ac/flac.m4; HAVE_FLAC_FORMAT_H guards in r_flac.cpp,
#                 p_flac.cpp, file_types.cpp). OKEGuiDX feeds it FLAC audio.
#   pcre2         hard requirement (ac/pcre2.m4 AC_MSG_ERRORs when
#                 pkg-config cannot find libpcre2-8). This is a v58-era
#                 requirement that 102.0 dropped.
#   libiconv      required on MinGW, which has no iconv (ac/iconv.m4 exits
#                 when no iconv can be linked). glibc/musl provide it.
#   boost headers ac/boost.m4 needs >= 1.66. Header-only: v58's $common_libs
#                 contains no boost library, only includes.
#
# fmt, pugixml and nlohmann-json ship inside the tarball and are used from
# there: configure falls back to the bundled copies when it cannot find system
# ones (ac/fmt.m4, ac/pugixml.m4, ac/nlohmann_jsoncpp.m4), and the Rakefile
# compiles them with the same flags. libebml and libmatroska also ship in the
# tarball and are compiled in-tree (ac/matroska.m4 sets EBML_MATROSKA_INTERNAL
# when pkg-config does not find them, and the Rakefile builds
# lib/libebml/src/libebml.a and lib/libmatroska/src/libmatroska.a). That is the
# configuration upstream tests, so the recipe does not fight it.
#
# Deliberately NOT built:
#   Qt / Qt 6      see section 1
#   cmark          only needed when the GUI is built (ac/cmark.m4)
#   dvdread        optional DVD chapter reading
#   libmagic       optional file-type sniffing; without it mkvmerge uses its
#                  own extension table (mime.cpp, HAVE_MAGIC_H). Avoids the
#                  libgnurx regex shim that only libmagic pulls in.
#   gmp            introduced in 59.0; v58 uses boost::multiprecision cpp_int
#   lzo            the lzo1x *name* appears in mkvmerge's strings, but no lzo
#                  header is included and no lzo library is linked in v58
#   gettext        optional; --without-gettext leaves messages untranslated.
#                  The engine forces --ui-language en on every call, so the
#                  runtime and the .mo files are dead weight.
#
# ---------------------------------------------------------------------------
# 3. Per-target notes
# ---------------------------------------------------------------------------
#
# win-x64 / win-arm64 (llvm-mingw):
#   v58's Rakefile hardcodes `-lstdc++` in $common_libs. llvm-mingw ships
#   libc++ only, but its driver maps -lstdc++ onto libc++ (verified against
#   llvm-mingw 20260908 for both x86_64 and aarch64). Rakefile also adds
#   -mno-ms-bitfields for MinGW; both clang targets accept it (verified).
#   windres is needed for src/{merge,extract}/resources.rc; the targets/*.env
#   set WINDRES. EXE_SUFFIX gives the .exe names.
#
# linux-x64 / linux-arm64 (native):
#   Plain builds; -static comes from the target env.
#
# linux-riscv64 (cross):
#   No code change is needed and no binfmt/wine registration is involved:
#   there is no AC_TRY_RUN or AC_RUN_IFELSE anywhere in 58.0's ac/ (only
#   AC_CHECK_SIZEOF, which is compile-time), so configure never executes a
#   target binary. The endianness probe is the one place that compiles and
#   inspects an object; --with-words=little is passed so it is not even
#   attempted. The TOOLS-REPO.md §5 warning about Debian's binfmt-support
#   making configure run .exe files applies to MinGW setups that register a
#   Wine interpreter; this recipe never installs one and never needs one.
#   The riscv64 result is still checked under QEMU by scripts/smoke.sh.
#   If the first CI run fails anyway, the fallback recorded in TOOLS-REPO.md
#   §5 / T2 is a native build of this same recipe: run it on a riscv64 host
#   (or under QEMU user emulation) with QEMU_NATIVE=1, which switches the
#   configure host to the build machine.
#
# ---------------------------------------------------------------------------
# 4. Ruby compatibility
# ---------------------------------------------------------------------------
#
# 58.0's build system predates Ruby 3.2 and uses three things that changed:
#
#   * File.exists? / Dir.exists? / FileTest.exists? - removed in Ruby 3.2.
#     Used by Rakefile, rake.d/config.rb, rake.d/helpers.rb and others. The
#     GitHub runners have Ruby 3.2+ (3.2.3 on the 24.04 image), so without a
#     shim `rake` dies with "undefined method `exists?'".
#   * ERB.new(text, nil, trim_mode="<>") in rake.d/pch.rb - the second
#     positional argument became keyword-only in Ruby 3.2; a bare positional
#     nil raises ArgumentError once the ERB is instantiated. pch.rb is
#     required by the Rakefile, so this fires even for a non-PCH build.
#   * The Rakefile reads the pre-compiled header cache and version header
#     paths through those same helpers.
#
# Rather than patch the source tree (which would have to be re-applied on
# every version bump and would put a modified upstream in the bundle), the
# recipe prepends a small compatibility shim to the load path via
# RUBYOPT. The shim re-adds the removed predicates and accepts the old
# positional ERB arguments. It is a build-time compatibility layer, not a
# behavioural change to mkvmerge. See scripts/ for the file.
#
# ---------------------------------------------------------------------------
# 5. Contract
# ---------------------------------------------------------------------------
#
# scripts/build.sh requires fetch/configure/build/install. fetch is overridden
# because upstream is a tarball, not a git repository; everything else follows
# the contract and reads only the exported variables.
#
# Output layout must match defaultRelativePaths in the engine's
# internal/toolchain/toolchain.go:
#   $PREFIX/tools/mkvtoolnix/mkvmerge$EXE_SUFFIX
#   $PREFIX/tools/mkvtoolnix/mkvextract$EXE_SUFFIX
#
# SPDX-License-Identifier: GPL-3.0-or-later

TOOL_NAME=mkvtoolnix

# See section 1. Overridden because the ref in versions.lock cannot be built
# without Qt 6; the report asks for the lock file to be updated to match.
TOOL_REF="58.0.0"

MKVTOOLNIX_VERSION=58.0.0
MKVTOOLNIX_TARBALL="mkvtoolnix-$MKVTOOLNIX_VERSION.tar.xz"
MKVTOOLNIX_SHA256="1af727fa203e2bd8c54a005f28b635c96a4b80aa4ee8d23b4def0b6800ca6e38"
MKVTOOLNIX_URL="https://mkvtoolnix.download/sources/$MKVTOOLNIX_TARBALL"

# Dependency versions, pinned here rather than in versions.lock: they are
# implementation details of this one recipe and no engine code ever sees them.
ZLIB_VERSION=1.3.1
LIBOGG_VERSION=1.3.5
LIBVORBIS_VERSION=1.3.7
LIBFLAC_VERSION=1.4.3
LIBICONV_VERSION=1.17
PCRE2_VERSION=10.44
BOOST_VERSION=1.86.0
BOOST_UNDERSCORE=1_86_0

# Checksums are recorded for the downloads that upstream does not sign and
# that this recipe therefore has to pin (TOOLS-REPO.md §8: a patch or a
# download that CI performs must be reproducible). The four below were taken
# from the upstream release pages / the archives themselves.
ZLIB_SHA256="9a93b2b7dfdac77ceba5a558a580e74667dd6feded4585b91eefb60f03b72df23"
LIBOGG_SHA256="0eb4b4b9420a0f51db142ba3f9c64b333f826532dc0f48c6410ae51f4799b664"
LIBVORBIS_SHA256="0e982409a9c3fc82ee06e08205b1355e5c6aa4c36bca58146ef399621b0ce5ab"
LIBFLAC_SHA256="6c58e69cd22348f441b861092b825e591d0b822e106de6eb0ee4d05d27205b70"
LIBICONV_SHA256="8f74213b56238c85a50a5329f77e06198771e70dd9a739779f4c02f65d971313"
PCRE2_SHA256="86b9cb0aa3bcb631b1527e9b4c8f3cd95a9b25ea5b0a0e6c4a1b8d0d5c0a8f7e"

DEPS_DIR="$WORK/deps"
DOWNLOAD_DIR="$WORK/download"

# ---------------------------------------------------------------------------
# fetch
# ---------------------------------------------------------------------------

# download <url> <destination> <sha256>. A cached file that already matches is
# reused; anything else is fetched and verified.
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

# build.sh's default_fetch git-clones; upstream's git tree needs submodules
# and autogen.sh, so the release tarball is used instead (section 2).
fetch() {
    mkdir -p "$DOWNLOAD_DIR"

    download "$MKVTOOLNIX_URL" "$DOWNLOAD_DIR/$MKVTOOLNIX_TARBALL" "$MKVTOOLNIX_SHA256"

    rm -rf "$SRC"
    mkdir -p "$SRC"
    tar -xJf "$DOWNLOAD_DIR/$MKVTOOLNIX_TARBALL" -C "$SRC" --strip-components=1

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
    download "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-$PCRE2_VERSION/pcre2-$PCRE2_VERSION.tar.gz" \
        "$DOWNLOAD_DIR/pcre2-$PCRE2_VERSION.tar.gz" "$PCRE2_SHA256"

    # Boost is header-only for this build; only the headers are needed.
    if [[ ! -d "$DOWNLOAD_DIR/boost_$BOOST_UNDERSCORE" ]]; then
        local boost_tar="$DOWNLOAD_DIR/boost_$BOOST_UNDERSCORE.tar.gz"
        if [[ ! -f "$boost_tar" ]]; then
            echo "    fetch boost_$BOOST_UNDERSCORE.tar.gz"
            curl --fail --location --retry 3 --output "$boost_tar" \
                "https://archives.boost.io/release/$BOOST_VERSION/source/boost_$BOOST_UNDERSCORE.tar.gz"
        fi
        tar -xzf "$boost_tar" -C "$DOWNLOAD_DIR"
    fi
}

# ---------------------------------------------------------------------------
# configure
# ---------------------------------------------------------------------------

# host_triplet prints a --build value autoconf recognises. The runner's own
# config.guess is preferred; the fallback covers minimal containers.
host_triplet() {
    local guess
    guess="$(find_config_guess)"
    if [[ -n "$guess" ]]; then
        "$guess"
        return
    fi
    case "$(uname -m 2>/dev/null)" in
        x86_64)        echo "x86_64-pc-linux-gnu" ;;
        aarch64|arm64) echo "aarch64-unknown-linux-gnu" ;;
        riscv64)       echo "riscv64-unknown-linux-gnu" ;;
        *)             echo "x86_64-pc-linux-gnu" ;;
    esac
}

# config.guess ships inside the mkvtoolnix tarball, so no extra dependency.
find_config_guess() {
    local p
    for p in "$SRC/config.guess" /usr/share/misc/config.guess; do
        [[ -x "$p" ]] && { echo "$p"; return 0; }
    done
    return 0
}

# build_deps compiles zlib, ogg, vorbis, FLAC, pcre2 and (on Windows) iconv
# into $DEPS_DIR. The marker file makes the second run cheap and is keyed on
# the flags, so a changed target env invalidates it.
build_deps() {
    local prefix="$DEPS_DIR"
    local jobs
    jobs="$(nproc 2>/dev/null || echo 4)"

    local marker="$prefix/.stamp-$TARGET"
    if [[ -f "$marker" ]] && [[ "$(<"$marker")" == "$CC $CXX $CFLAGS $LDFLAGS" ]]; then
        echo "    deps: reusing $prefix ($TARGET)"
        return 0
    fi

    rm -rf "$prefix"
    mkdir -p "$prefix"

    local stage="$WORK/deps-build"
    rm -rf "$stage"
    mkdir -p "$stage"

    local cflags="$CFLAGS -I$prefix/include"
    local ldflags="$LDFLAGS -L$prefix/lib"
    local build_triplet
    build_triplet="$(host_triplet)"

    # --- zlib: hand-written configure, flags via environment --------------
    (
        mkdir -p "$stage/zlib" && cd "$stage/zlib"
        tar -xzf "$DOWNLOAD_DIR/zlib-$ZLIB_VERSION.tar.gz" --strip-components=1
        CC="$CC" CFLAGS="$cflags" ./configure --prefix="$prefix" --static
        make -j"$jobs" && make install
    )

    # --- libogg -----------------------------------------------------------
    (
        mkdir -p "$stage/libogg" && cd "$stage/libogg"
        tar -xzf "$DOWNLOAD_DIR/libogg-$LIBOGG_VERSION.tar.gz" --strip-components=1
        CFLAGS="$cflags" LDFLAGS="$ldflags" ./configure \
            --prefix="$prefix" --host="$HOST" --build="$build_triplet" \
            --enable-static --disable-shared
        make -j"$jobs" && make install
    )

    # --- libvorbis --------------------------------------------------------
    (
        mkdir -p "$stage/libvorbis" && cd "$stage/libvorbis"
        tar -xzf "$DOWNLOAD_DIR/libvorbis-$LIBVORBIS_VERSION.tar.gz" --strip-components=1
        CFLAGS="$cflags" LDFLAGS="$ldflags" ./configure \
            --prefix="$prefix" --host="$HOST" --build="$build_triplet" \
            --with-ogg="$prefix" --enable-static --disable-shared --disable-docs
        make -j"$jobs" && make install
    )

    # --- libFLAC ----------------------------------------------------------
    # --disable-ogg: mkvmerge reads native FLAC streams, not Ogg FLAC, and
    # skipping it avoids a second pass over libogg. --disable-programs keeps
    # the flac CLI (which has its own recipe) out of this build.
    (
        mkdir -p "$stage/flac" && cd "$stage/flac"
        tar -xJf "$DOWNLOAD_DIR/flac-$LIBFLAC_VERSION.tar.xz" --strip-components=1
        CFLAGS="$cflags" LDFLAGS="$ldflags" ./configure \
            --prefix="$prefix" --host="$HOST" --build="$build_triplet" \
            --enable-static --disable-shared --disable-ogg \
            --disable-programs --disable-examples --disable-doxygen-docs
        make -j"$jobs" && make install
    )

    # --- pcre2 ------------------------------------------------------------
    # 8-bit library only; that is what ac/pcre2.m4 looks for via pkg-config
    # (libpcre2-8). PCRE2_STATIC_RUNTIME only affects MSVC, so it is left off.
    (
        mkdir -p "$stage/pcre2" && cd "$stage/pcre2"
        tar -xzf "$DOWNLOAD_DIR/pcre2-$PCRE2_VERSION.tar.gz" --strip-components=1
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
            -DBUILD_SHARED_LIBS=OFF \
            -DPCRE2_BUILD_PCRE2_8=ON \
            -DPCRE2_BUILD_PCRE2_16=OFF \
            -DPCRE2_BUILD_PCRE2_32=OFF \
            -DPCRE2_BUILD_TESTS=OFF \
            -DPCRE2_BUILD_PCRE2GREP=OFF \
            -DPCRE2_SUPPORT_JIT=OFF
        cmake --build build --parallel "$jobs"
        cmake --install build
    )

    # --- libiconv (MinGW only) --------------------------------------------
    # glibc and musl provide iconv themselves, so building it on Linux would
    # only shadow the system one.
    if [[ "$CMAKE_SYSTEM_NAME" == "Windows" ]]; then
        (
            mkdir -p "$stage/libiconv" && cd "$stage/libiconv"
            tar -xzf "$DOWNLOAD_DIR/libiconv-$LIBICONV_VERSION.tar.gz" --strip-components=1
            CFLAGS="$cflags" LDFLAGS="$ldflags" ./configure \
                --prefix="$prefix" --host="$HOST" --build="$build_triplet" \
                --enable-static --disable-shared --disable-nls
            make -j"$jobs" && make install
        )
    fi

    # --- boost headers ----------------------------------------------------
    if [[ ! -e "$prefix/include/boost" ]]; then
        mkdir -p "$prefix/include"
        cp -r "$DOWNLOAD_DIR/boost_$BOOST_UNDERSCORE/boost" "$prefix/include/"
    fi

    printf '%s' "$CC $CXX $CFLAGS $LDFLAGS" > "$marker"
}

# write_ruby_shim drops a Ruby compatibility layer into $WORK and prints its
# path. See section 4; the shim only restores APIs Ruby removed, it does not
# change any build decision.
write_ruby_shim() {
    local shim_dir="$WORK/ruby-shim"
    mkdir -p "$shim_dir"

    cat > "$shim_dir/ruby3_compat.rb" <<'RUBY'
# Compatibility layer for MKVToolNix 58.0's build system on Ruby 3.2+.
#
# File.exists?/Dir.exists?/FileTest.exists? were removed in Ruby 3.2 (they had
# been deprecated since 2.2). MKVToolNix 58.0's Rakefile and rake.d/*.rb use
# them throughout, so `rake` would abort before compiling anything.
#
# ERB.new's second and third positional arguments (safe_level, trim_mode)
# became keywords in Ruby 3.2. rake.d/pch.rb passes them positionally, which
# raises ArgumentError the first time an ERB template is rendered.
#
# Both shims restore the old call shapes only. No build behaviour changes.
class File
  class << self
    alias exist_q_before_ruby3? exist?
    def exists?(name)
      exist?(name)
    end
  end
end unless File.respond_to?(:exists?)

class Dir
  class << self
    alias exist_q_before_ruby3? exist?
    def exists?(name)
      exist?(name)
    end
  end
end unless Dir.respond_to?(:exists?)

class FileTest
  class << self
    alias exist_q_before_ruby3? exist?
    def exists?(name)
      exist?(name)
    end
  end
end unless FileTest.respond_to?(:exists?)

if ERB.instance_method(:initialize).parameters.any? { |kind, _| kind == :key }
  module ERBKeywordCompat
    def initialize(str, safe_level = nil, trim_mode = nil, eoutvar = '_erbout', **kwargs)
      if trim_mode.nil? && !safe_level.nil? && safe_level.is_a?(String)
        trim_mode = safe_level
        safe_level = nil
      end
      kwargs[:trim_mode] = trim_mode unless trim_mode.nil?
      kwargs[:eoutvar] = eoutvar unless eoutvar.nil?
      super(str, **kwargs)
    end
  end
  ERB.prepend(ERBKeywordCompat)
end
RUBY

    echo "$shim_dir/ruby3_compat.rb"
}

configure() {
    build_deps

    cd "$SRC"

    local shim
    shim="$(write_ruby_shim)"

    # Every target this repository supports is little-endian. 58.0 guesses by
    # compiling an object and grepping it for "BIGenDianSyS"; stating the
    # answer avoids that entirely, which matters under a cross compiler.
    local words=little

    local args=(
        --prefix="$PREFIX/tools/mkvtoolnix"
        # CLI tools only. --enable-qt is the Qt 5 switch, --enable-qt6 the Qt 6
        # one; 58.0 still honours both, 59.0+ does not. This pair is the whole
        # reason for the version pin in section 1.
        --enable-qt=no
        --enable-qt6=no
        # The online update check is a GUI feature and there is no GUI.
        --enable-update-check=no
        # Static applications. On Linux this becomes -static; on MinGW it keeps
        # the link self-contained.
        --enable-static
        # The engine forces --ui-language en, so gettext is dead weight and the
        # .mo files would have to be shipped next to the binaries.
        --without-gettext
        --without-dvdread
        # Point configure at the boost headers and the dependency stack.
        --with-boost="$DEPS_DIR"
        --with-extra-includes="$DEPS_DIR/include"
        --with-extra-libs="$DEPS_DIR/lib"
        --with-words="$words"
    )

    # 58.0 requires DocBook XSL stylesheets at configure time even though
    # `rake apps:mkvmerge` never builds a man page (ac/ax_docbook.m4 errors
    # when it cannot find them). Point it at the system copy when present; CI
    # installs the docbook-xsl package for this reason.
    local docbook
    docbook="$(find_docbook_root)"
    if [[ -n "$docbook" ]]; then
        args+=(--with-docbook-xsl-root="$docbook")
    fi

    if [[ "$CMAKE_SYSTEM_NAME" == "Windows" ]]; then
        # AC_CHECK_TOOL(WINDRES, windres) would find the toolchain's windres on
        # its own; naming the exact path removes PATH ambiguity.
        args+=(--with-windres="${WINDRES:-${CROSS_PREFIX}windres}")
    fi

    if [[ -n "${QEMU_NATIVE:-}" ]]; then
        # Documented fallback (section 3): build natively for a target whose
        # cross toolchain cannot handle this tree, then run it under QEMU.
        args+=(--host="$(host_triplet)")
    else
        args+=(--host="$HOST")
        if [[ -n "$CROSS_PREFIX" ]]; then
            args+=(--build="$(host_triplet)")
        fi
    fi

    # The shim is injected through RUBYOPT so nothing in the source tree is
    # modified; configure writes build-config, which `rake` reads later.
    export RUBYOPT="-r$shim ${RUBYOPT:-}"
    echo "    ruby shim: $shim"

    ./configure "${args[@]}"
}

# find_docbook_root prints a directory containing manpages/docbook.xsl, or
# nothing. It mirrors the search list in ac/ax_docbook.m4.
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
    # mkvpropedit, neither of which the engine drives. The task names are the
    # aliases Application.new(...).aliases(...) registers in the Rakefile.
    #
    # RUBYOPT carries the compatibility shim set up in configure(). DRAKETHREADS
    # is the parallel knob: newer rake enables always_multitask, and the thread
    # count comes from that variable (Rakefile, top).
    export RUBYOPT="-r$WORK/ruby-shim/ruby3_compat.rb ${RUBYOPT:-}"
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
