#!/usr/bin/env bash
#
# mkvtoolnix recipe - mkvmerge and mkvextract, the container layer.
#
# This is the hardest recipe in the tree. The reason is not the dependency
# count but the version: upstream made Qt mandatory for the command-line tools
# in 59.0, so every later release needs a full Qt cross-build for targets where
# Qt does not even exist as a distribution package. Read this header before
# changing anything.
#
# ---------------------------------------------------------------------------
# 1. Why 58.0.0 is the newest usable release
# ---------------------------------------------------------------------------
#
# The engine only ever drives the two CLI programs (see
# internal/jobproc/mux/simple/*.go and TChapter's MATROKAParser). Upstream
# 59.0.0 onwards cannot produce those without Qt:
#
#   * 59.0.0 (2021-07-10) made Qt mandatory for every binary, mkvmerge
#     included. Its NEWS.md, "Build system changes", states it outright: "The
#     Qt library is now required for building all applications, even the
#     command-line ones, as they use Qt's MIME type detection capabilities. In
#     turn this means that you cannot disable the Qt usage anymore."
#   * From 85.0 onwards ac/qt6.m4 fails unconditionally with "The Qt library
#     version >= ... is required for building MKVToolNix." There is no
#     --disable-qt any more; --enable-gui only drops the GUI. 102.0 has only
#     ac/qt6.m4 and no ac/qt5.m4 at all.
#   * src/common/mime.cpp from 59.0 on uses QMimeDatabase with no #if guard,
#     and mkvmerge.cpp calls mtx::mime::guess_type() for every input file, so
#     the QtCore dependency is real code, not a configure quirk.
#
# Cross-compiling Qt 6 for five targets - including riscv64, which has no Qt
# packages on any distribution - is the "tens of minutes becomes hours"
# blow-up TOOLS-REPO.md §5 warns about. It would also ship a Qt the engine
# never touches.
#
# 58.0.0 is the last release whose CLI tools are genuinely Qt-free:
#
#   * ac/qt6.m4 gates Qt 6 behind --enable-qt6 (default yes) and ac/qt5.m4
#     gates Qt 5 behind --enable-qt (default yes), so --enable-qt=no
#     --enable-qt6=no disables both. The Rakefile then leaves USE_QT unset,
#     $build_mkvtoolnix_gui stays false, and no Qt code is linked.
#   * The only Qt-using files in src/common are qt.h, qt_kax_analyzer.{h,cpp},
#     qt6_compat/* and the event/library_info/meta_type/mutex shims. The first
#     two are wrapped in `#if defined(HAVE_QT)`, which configure only defines
#     when a Qt was found, so the flags compile them away.
#   * 58.0.0 predates the --default-track -> --default-track-flag rename (65.0)
#     but mkvmerge keeps the old spelling as an alias "indefinitely" (65.0
#     NEWS), and 102.0 still accepts --default-track in its argument parser, so
#     the engine's argv works on both. Every other option the engine passes
#     exists in 58.0: --append-to, --chapters, --chapter-language, --split
#     parts-frames:, --track-order, --track-name, --timestamps, --no-*.
#     (Checked against doc/man/mkvmerge.xml in the 58.0.0 tarball.)
#   * 58.0.0 prints the "Multiplexing took" success line that
#     internal/jobproc/mux/simple/mkvmerge.go keys on, and "Progress: N%" on
#     stdout exactly as its parser expects.
#
# versions.lock records 58.0.0 for this reason; see the comment above its
# mkvtoolnix entry. Bumping that ref means committing to a Qt 6 cross-build
# for every target and rewriting this header.
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
# It ships `configure` (so no autoconf/automake in CI), config.sub/config.guess
# (so cross targets configure correctly), and bundled libebml, libmatroska,
# fmt, pugixml, nlohmann-json, utf8-cpp and jpcre2. Using it avoids three
# submodule fetches and an autogen.sh run, and it is the artefact upstream
# supports. The recipe's fetch() therefore overrides build.sh's git clone.
#
# Dependencies are built into the shared per-target dependency tree ($DEPS,
# out/<target>/deps) that scripts/build.sh hands to every recipe:
#
#   zlib          configure hard-fails without it (ac/zlib.m4). Built by the
#                 zlib recipe through require_dependency, like ffmpeg does.
#   libogg        hard requirement (ac/ogg.m4)
#   libvorbis     hard requirement (ac/vorbis.m4)
#   libFLAC       wanted: without it mkvmerge cannot read FLAC tracks at all
#                 (ac/flac.m4; HAVE_FLAC_FORMAT_H guards in r_flac.cpp,
#                 p_flac.cpp, file_types.cpp). OKEGuiDX feeds it FLAC audio.
#   pcre2         hard requirement (ac/pcre2.m4 AC_MSG_ERRORs when pkg-config
#                 cannot find libpcre2-8). A v58-era requirement that 102.0
#                 dropped; the bundled jpcre2 needs it.
#   libiconv      required on MinGW, which has no iconv (ac/iconv.m4 exits when
#                 no iconv can be linked). glibc and musl provide it, so it is
#                 only built for the Windows targets.
#   boost headers ac/boost.m4 needs >= 1.66 and checks cpp_int.hpp,
#                 operators.hpp and rational.hpp. Header-only: 58.0's
#                 $common_libs contains no boost library, only includes.
#
# fmt, pugixml, nlohmann-json, libebml and libmatroska ship inside the tarball
# and are used from there. configure falls back to the bundled copies when it
# cannot find system ones (ac/fmt.m4, ac/pugixml.m4, ac/nlohmann_jsoncpp.m4,
# ac/matroska.m4) and the Rakefile compiles them with the same flags. That is
# the configuration upstream tests, so this recipe does not fight it. In
# particular libebml/libmatroska are compiled in-tree rather than from the
# separate libebml/libmatroska recipes, because configure's pkg-config check
# would otherwise pick up a different version than the one upstream shipped.
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
#                  runtime and the .mo files would be dead weight.
#
# ---------------------------------------------------------------------------
# 3. Per-target notes
# ---------------------------------------------------------------------------
#
# win-x64 / win-arm64 (llvm-mingw):
#   The Rakefile hardcodes `-lstdc++` in $common_libs. llvm-mingw ships libc++
#   only, but its driver maps -lstdc++ onto libc++ (verified against
#   llvm-mingw 20260908 for both x86_64 and aarch64). The Rakefile also adds
#   -mno-ms-bitfields for MinGW, which both clang targets accept (verified).
#   windres is needed for src/{merge,extract}/resources.rc; configure's
#   AC_CHECK_TOOL(WINDRES, windres) finds the toolchain's one through the host
#   prefix. EXE_SUFFIX gives the .exe names.
#
# linux-x64 / linux-arm64 (native):
#   Plain builds; -static comes from the target env.
#
# linux-riscv64 (cross):
#   No binfmt/wine registration is involved and none is needed. There is no
#   AC_TRY_RUN or AC_RUN_IFELSE anywhere in 58.0's ac/ (only AC_CHECK_SIZEOF,
#   which is compile-time), so configure never executes a target binary. The
#   endianness probe is the one place that compiles and inspects an object;
#   --with-words=little is passed so it is not even attempted. The
#   TOOLS-REPO.md §5 warning about Debian's binfmt-support making configure run
#   .exe files applies to MinGW setups that register a Wine interpreter, which
#   this recipe never does. The riscv64 result is still checked under QEMU by
#   scripts/smoke.sh.
#   If the first CI run fails anyway, the fallback recorded in TOOLS-REPO.md
#   §5 / T2 is a native build of this same recipe on a riscv64 host (or under
#   QEMU user emulation) with QEMU_NATIVE=1, which switches the configure host
#   to the build machine.
#
# ---------------------------------------------------------------------------
# 4. Ruby compatibility
# ---------------------------------------------------------------------------
#
# 58.0's build system predates Ruby 3.2, which removed File.exists?,
# Dir.exists? and FileTest.exists?. The Rakefile and rake.d/{config,helpers,
# iso15924,iana_language_subtag_registry,tarball}.rb use them, and
# rake.d/config.rb runs during startup, so `rake` aborts with "undefined method
# `exists?'" before compiling anything. The GitHub runners ship Ruby 3.2+
# (3.2.3 on the 24.04 image).
#
# Rather than patch the source tree (which would have to be re-applied on every
# version bump and would put a modified upstream in the bundle), the recipe
# writes a small shim into $WORK and loads it with RUBYOPT. The shim restores
# only the three removed predicates; it changes no build decision, and it is
# not part of the shipped bundle.
#
# rake.d/pch.rb also calls ERB.new(text, nil, trim_mode="<>"). That is only a
# deprecation warning on Ruby 3.2+ (the trim_mode is already passed by
# keyword), so it needs no shim; verified against ERB 4.x's signature.
#
# ---------------------------------------------------------------------------
# 5. CI dependencies this recipe needs installed
# ---------------------------------------------------------------------------
#
# Unlike every other recipe, this one needs build-time tools beyond a compiler:
#
#   ruby + rake   the build system itself. The GitHub runners already ship
#                 Ruby 3.2+, but rake is only guaranteed inside a full Ruby
#                 install; Debian/Ubuntu split it into the `rake` package and
#                 Alpine into `ruby-rake`.
#   xsltproc      ac/ax_docbook.m4 runs it during configure and fails without.
#                 Debian/Ubuntu: `xsltproc`; Alpine: `libxslt`.
#   docbook-xsl   ac/ax_docbook.m4 aborts with "DocBook XSL stylesheets are
#                 required for building." when it cannot find
#                 manpages/docbook.xsl. Debian/Ubuntu: `docbook-xsl`;
#                 Alpine: `docbook-xsl`.
#
# check_build_prerequisites() below fails with those package names if anything
# is missing, so the first CI failure (if any) is self-explaining. The workflow
# file .github/workflows/build.yml currently installs none of them, so the
# mkvtoolnix matrix entries need these added to both the apt-get and apk steps.
# That file is outside this recipe's scope and was not modified; see the C6
# report.
#
# ---------------------------------------------------------------------------
# 6. Contract
# ---------------------------------------------------------------------------
#
# scripts/build.sh requires fetch/configure/build/install. fetch is overridden
# because upstream ships a tarball rather than a git repository; everything
# else follows the contract and reads only the exported variables.
#
# Output layout must match defaultRelativePaths in the engine's
# internal/toolchain/toolchain.go:
#   $PREFIX/tools/mkvtoolnix/mkvmerge$EXE_SUFFIX
#   $PREFIX/tools/mkvtoolnix/mkvextract$EXE_SUFFIX
#
# SPDX-License-Identifier: GPL-3.0-or-later

TOOL_NAME=mkvtoolnix

# versions.lock carries the single entry under the "upstream" variant, so a
# bare `build.sh mkvtoolnix <target>` has to select it before build.sh does its
# lookup. Same pattern as x265.
TOOL_VARIANT="${VARIANT:-upstream}"

# require_dependency in scripts/build.sh passes ${VARIANT:-} straight through to
# the dependency's build, and the dependency's versions.lock entry is also
# "upstream". Without this, a bare `build.sh mkvtoolnix <target>` would resolve
# mkvtoolnix but then ask for zlib with an empty variant and fail. VARIANT is
# exported by build.sh and the recipe is sourced into the same shell, so
# setting it here is what makes the documented bare invocation work.
VARIANT="${VARIANT:-upstream}"

# NOTE ON TIMING: scripts/build.sh sources this file before it sets WORK, SRC,
# PREFIX, DEPS and before it resolves TOOL_REPO/TOOL_REF from versions.lock.
# Every variable that depends on those therefore has to be computed inside a
# function, not at the top level. Only TOOL_NAME, TOOL_VARIANT and the constant
# pins below may live here.

# Dependency versions. These are implementation details of this one recipe and
# no engine code ever sees them, so they live here rather than in versions.lock.
LIBOGG_VERSION=1.3.5
LIBVORBIS_VERSION=1.3.7
LIBFLAC_VERSION=1.4.3
LIBICONV_VERSION=1.17
PCRE2_VERSION=10.44
BOOST_VERSION=1.86.0
BOOST_UNDERSCORE=1_86_0

# Digests for everything downloaded at build time, so CI builds are
# reproducible and a swapped tarball is caught (TOOLS-REPO.md §8).
LIBOGG_SHA256="0eb4b4b9420a0f51db142ba3f9c64b333f826532dc0f48c6410ae51f4799b664"
LIBVORBIS_SHA256="0e982409a9c3fc82ee06e08205b1355e5c6aa4c36bca58146ef399621b0ce5ab"
LIBFLAC_SHA256="6c58e69cd22348f441b861092b825e591d0b822e106de6eb0ee4d05d27205b70"
LIBICONV_SHA256="8f74213b56238c85a50a5329f77e06198771e70dd9a739779f4c02f65d971313"
PCRE2_SHA256="86b9cb0aa3bcb7994faa88018292bc704cdbb708e785f7c74352ff6ea7d3175b"

# mkvtoolnix_version prints the version from the lock file's ref. versions.lock
# records it without a "v" prefix; the git tags carry one.
mkvtoolnix_version() {
    echo "${TOOL_REF#v}"
}

# mkvtoolnix_tarball_url prints the release tarball URL. TOOL_REPO in
# versions.lock is the download directory rather than a git URL.
mkvtoolnix_tarball_url() {
    echo "${TOOL_REPO:-https://mkvtoolnix.download/sources}/mkvtoolnix-$(mkvtoolnix_version).tar.xz"
}

# mkvtoolnix_sha256 prints the recorded digest of the tarball. A ref bumped in
# versions.lock without adding its digest here fails the build rather than
# silently fetching something unverified.
mkvtoolnix_sha256() {
    case "$(mkvtoolnix_version)" in
        58.0.0) echo "1af727fa203e2bd8c54a005f28b635c96a4b80aa4ee8d23b4def0b6800ca6e38" ;;
        *)
            echo "mkvtoolnix: no sha256 recorded for $(mkvtoolnix_version); add it to" >&2
            echo "            mkvtoolnix_sha256() in recipes/mkvtoolnix.sh first." >&2
            exit 1
            ;;
    esac
}

# download_dir is the per-work-directory download cache.
download_dir() {
    echo "$WORK/download"
}

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

fetch() {
    local dl
    dl="$(download_dir)"
    mkdir -p "$dl"

    download "$(mkvtoolnix_tarball_url)" \
        "$dl/mkvtoolnix-$(mkvtoolnix_version).tar.xz" "$(mkvtoolnix_sha256)"

    rm -rf "$SRC"
    mkdir -p "$SRC"
    tar -xJf "$dl/mkvtoolnix-$(mkvtoolnix_version).tar.xz" -C "$SRC" --strip-components=1

    download "https://downloads.xiph.org/releases/ogg/libogg-$LIBOGG_VERSION.tar.gz" \
        "$dl/libogg-$LIBOGG_VERSION.tar.gz" "$LIBOGG_SHA256"
    download "https://downloads.xiph.org/releases/vorbis/libvorbis-$LIBVORBIS_VERSION.tar.gz" \
        "$dl/libvorbis-$LIBVORBIS_VERSION.tar.gz" "$LIBVORBIS_SHA256"
    download "https://downloads.xiph.org/releases/flac/flac-$LIBFLAC_VERSION.tar.xz" \
        "$dl/flac-$LIBFLAC_VERSION.tar.xz" "$LIBFLAC_SHA256"
    download "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-$PCRE2_VERSION/pcre2-$PCRE2_VERSION.tar.gz" \
        "$dl/pcre2-$PCRE2_VERSION.tar.gz" "$PCRE2_SHA256"

    if [[ "$CMAKE_SYSTEM_NAME" == "Windows" ]]; then
        download "https://ftp.gnu.org/pub/gnu/libiconv/libiconv-$LIBICONV_VERSION.tar.gz" \
            "$dl/libiconv-$LIBICONV_VERSION.tar.gz" "$LIBICONV_SHA256"
    fi

    # Boost is header-only for this build. The archive host publishes no
    # sidecar checksum; the version is pinned in the URL instead.
    if [[ ! -d "$dl/boost_$BOOST_UNDERSCORE" ]]; then
        local boost_tar="$dl/boost_$BOOST_UNDERSCORE.tar.gz"
        if [[ ! -f "$boost_tar" ]]; then
            echo "    fetch boost_$BOOST_UNDERSCORE.tar.gz"
            curl --fail --location --retry 3 --output "$boost_tar" \
                "https://archives.boost.io/release/$BOOST_VERSION/source/boost_$BOOST_UNDERSCORE.tar.gz"
        fi
        tar -xzf "$boost_tar" -C "$dl"
    fi
}

# ---------------------------------------------------------------------------
# configure
# ---------------------------------------------------------------------------

# host_triplet prints a --build value autoconf recognises. The tarball's own
# config.guess is preferred; the fallback covers minimal containers.
host_triplet() {
    if [[ -x "$SRC/config.guess" ]]; then
        "$SRC/config.guess"
        return
    fi
    case "$(uname -m 2>/dev/null)" in
        x86_64)        echo "x86_64-pc-linux-gnu" ;;
        aarch64|arm64) echo "aarch64-unknown-linux-gnu" ;;
        riscv64)       echo "riscv64-unknown-linux-gnu" ;;
        *)             echo "x86_64-pc-linux-gnu" ;;
    esac
}

# write_ruby_shim writes the Ruby 3 compatibility layer described in section 4
# into $WORK and prints its path. It is idempotent.
write_ruby_shim() {
    local shim_dir="$WORK/ruby-shim"
    mkdir -p "$shim_dir"

    cat > "$shim_dir/ruby3_compat.rb" <<'RUBY'
# Compatibility layer for MKVToolNix 58.0's build system on Ruby 3.2+.
#
# File.exists?/Dir.exists?/FileTest.exists? were removed in Ruby 3.2 (they had
# been deprecated since 2.1). MKVToolNix 58.0's Rakefile and several rake.d
# helpers use them, so `rake` would abort before compiling anything. Only the
# removed call shapes are restored; no build behaviour changes.
#
# File and Dir are classes; FileTest is a module, so each gets the form its
# definition requires. File includes FileTest, and re-opening File with the
# predicate below also gives File.exists? for free, but File is patched
# explicitly so the shim does not depend on that.
unless File.respond_to?(:exists?)
  class File
    class << self
      def exists?(name)
        exist?(name)
      end
    end
  end
end

unless Dir.respond_to?(:exists?)
  class Dir
    class << self
      def exists?(name)
        exist?(name)
      end
    end
  end
end

unless FileTest.respond_to?(:exists?)
  module FileTest
    class << self
      def exists?(name)
        exist?(name)
      end
    end
  end
end
RUBY

    echo "$shim_dir/ruby3_compat.rb"
}

# check_build_prerequisites fails early with an actionable message rather than
# letting configure report a missing tool five minutes in.
check_build_prerequisites() {
    local missing=()

    command -v rake >/dev/null 2>&1 || missing+=(rake)
    command -v ruby >/dev/null 2>&1 || missing+=(ruby)
    command -v xsltproc >/dev/null 2>&1 || missing+=(xsltproc)
    [[ -n "$(find_docbook_root)" ]] || missing+=(docbook-xsl)

    if (( ${#missing[@]} )); then
        echo "mkvtoolnix: missing build prerequisites: ${missing[*]}" >&2
        echo "  Debian/Ubuntu: sudo apt-get install -y ruby rake xsltproc docbook-xsl" >&2
        echo "  Alpine:        apk add --no-cache ruby ruby-rake libxslt docbook-xsl" >&2
        exit 1
    fi
}

# find_docbook_root prints a directory containing manpages/docbook.xsl, or
# nothing. It mirrors the search list in ac/ax_docbook.m4, which 58.0 runs
# unconditionally even though `rake apps:mkvmerge` never builds a man page.
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

# build_deps compiles ogg, vorbis, FLAC, pcre2, iconv and the boost headers
# into $DEPS. zlib comes from the shared zlib recipe. The marker file makes a
# second run cheap and is keyed on the flags, so a changed target env
# invalidates it.
build_deps() {
    local prefix="$DEPS"
    local dl
    dl="$(download_dir)"
    local jobs
    jobs="$(nproc 2>/dev/null || echo 4)"

    # --- boost headers ----------------------------------------------------
    # Header-only: AX_BOOST_BASE only needs <path>/include/boost/version.hpp,
    # and AX_BOOST_CHECK_HEADERS then compiles against the individual headers.
    # A staging directory in $WORK holds an `include/boost` symlink so the
    # ~90k header files are not copied. It lives outside $DEPS on purpose: the
    # CI job uploads out/<target>/ as an artifact, and a symlink into work/
    # would dangle there. This is done before the marker check because
    # configure() needs the path on every run, including the cached ones.
    local boost_stage="$WORK/boost-stage"
    rm -rf "$boost_stage"
    mkdir -p "$boost_stage/include"
    if ! ln -sfn "$dl/boost_$BOOST_UNDERSCORE/boost" "$boost_stage/include/boost" 2>/dev/null; then
        cp -r "$dl/boost_$BOOST_UNDERSCORE/boost" "$boost_stage/include/"
    fi

    local marker="$prefix/.mkvtoolnix-deps-$TARGET"
    if [[ -f "$marker" ]] && [[ "$(<"$marker")" == "$CC $CXX $CFLAGS $LDFLAGS" ]]; then
        echo "    deps: reusing $prefix ($TARGET)"
        return 0
    fi

    local stage="$WORK/deps-build"
    rm -rf "$stage"
    mkdir -p "$stage"

    local cflags="$CFLAGS -I$prefix/include"
    local ldflags="$LDFLAGS -L$prefix/lib"
    local build_triplet
    build_triplet="$(host_triplet)"

    # --- libogg -----------------------------------------------------------
    (
        mkdir -p "$stage/libogg" && cd "$stage/libogg"
        tar -xzf "$dl/libogg-$LIBOGG_VERSION.tar.gz" --strip-components=1
        CFLAGS="$cflags" LDFLAGS="$ldflags" ./configure \
            --prefix="$prefix" --host="$HOST" --build="$build_triplet" \
            --enable-static --disable-shared
        make -j"$jobs" && make install
    )

    # --- libvorbis --------------------------------------------------------
    (
        mkdir -p "$stage/libvorbis" && cd "$stage/libvorbis"
        tar -xzf "$dl/libvorbis-$LIBVORBIS_VERSION.tar.gz" --strip-components=1
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
        tar -xJf "$dl/flac-$LIBFLAC_VERSION.tar.xz" --strip-components=1
        CFLAGS="$cflags" LDFLAGS="$ldflags" ./configure \
            --prefix="$prefix" --host="$HOST" --build="$build_triplet" \
            --enable-static --disable-shared --disable-ogg \
            --disable-programs --disable-examples --disable-doxygen-docs
        make -j"$jobs" && make install
    )

    # --- pcre2 ------------------------------------------------------------
    # 8-bit library only: ac/pcre2.m4 looks for libpcre2-8 via pkg-config, and
    # jpcre2 (bundled) is compiled against the same 8-bit API.
    #
    # The autotools build has no switch for the pcre2grep/pcre2test programs
    # (they are unconditional bin_PROGRAMS when the 8-bit library is enabled),
    # so they are built but never installed: only the library, headers and
    # pkg-config file matter, and the recipe links the archive from $DEPS.
    # Building two small extra programs is cheaper than maintaining a patch.
    (
        mkdir -p "$stage/pcre2" && cd "$stage/pcre2"
        tar -xzf "$dl/pcre2-$PCRE2_VERSION.tar.gz" --strip-components=1
        CFLAGS="$cflags" LDFLAGS="$ldflags" ./configure \
            --prefix="$prefix" --host="$HOST" --build="$build_triplet" \
            --enable-static --disable-shared \
            --enable-pcre2-8 --disable-pcre2-16 --disable-pcre2-32 \
            --disable-jit --disable-pcre2grep-jit
        make -j"$jobs" && make install
    )

    # --- libiconv (MinGW only) --------------------------------------------
    # glibc and musl provide iconv themselves, so building it on Linux would
    # only shadow the system one.
    if [[ "$CMAKE_SYSTEM_NAME" == "Windows" ]]; then
        (
            mkdir -p "$stage/libiconv" && cd "$stage/libiconv"
            tar -xzf "$dl/libiconv-$LIBICONV_VERSION.tar.gz" --strip-components=1
            CFLAGS="$cflags" LDFLAGS="$ldflags" ./configure \
                --prefix="$prefix" --host="$HOST" --build="$build_triplet" \
                --enable-static --disable-shared --disable-nls
            make -j"$jobs" && make install
        )
    fi

    printf '%s' "$CC $CXX $CFLAGS $LDFLAGS" > "$marker"
}

# boost_stage_dir prints the staging directory build_deps created.
boost_stage_dir() {
    echo "$WORK/boost-stage"
}

configure() {
    check_build_prerequisites

    # zlib is the one dependency another recipe already provides; reuse it so
    # the target tree holds a single copy (ffmpeg does the same).
    require_dependency zlib

    build_deps

    cd "$SRC"

    local shim
    shim="$(write_ruby_shim)"

    # pkg-config must see only the target's dependency tree. Without
    # PKG_CONFIG_LIBDIR a cross build would happily find host libebml or
    # libmatroska and try to link host binaries into a Windows executable.
    export PKG_CONFIG_PATH="$DEPS/lib/pkgconfig:$DEPS/share/pkgconfig"
    export PKG_CONFIG_LIBDIR="$DEPS/lib/pkgconfig:$DEPS/share/pkgconfig"

    # Every target this repository supports is little-endian. 58.0 guesses by
    # compiling an object and grepping it for "BIGenDianSyS"; stating the
    # answer avoids that entirely, which matters under a cross compiler.
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
        # Point configure at the boost headers and the dependency tree. The
        # values must not contain an '=' sign: ac/extra_inc_lib.m4 recovers the
        # path with `cut -d '=' -f 2`, so a path containing '=' would be
        # truncated. Paths under the CI work directory never contain one.
        --with-boost="$(boost_stage_dir)"
        --with-extra-includes="$DEPS/include"
        --with-extra-libs="$DEPS/lib"
        --with-words=little
    )

    # 58.0 requires DocBook XSL stylesheets at configure time even though
    # `rake apps:mkvmerge` never builds a man page (ac/ax_docbook.m4 errors
    # when it cannot find them). check_build_prerequisites has already
    # confirmed they exist.
    local docbook
    docbook="$(find_docbook_root)"
    if [[ -n "$docbook" ]]; then
        args+=(--with-docbook-xsl-root="$docbook")
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
    # modified. configure itself is a shell script and does not need it, but
    # exporting here means build() inherits it even if it is invoked alone.
    export RUBYOPT="-r$shim ${RUBYOPT:-}"
    echo "    ruby shim: $shim"

    ./configure "${args[@]}"
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
    # RUBYOPT carries the compatibility shim from section 4; write_ruby_shim is
    # idempotent so build() works even when called on its own. DRAKETHREADS is
    # the parallel knob: newer rake enables always_multitask, and the thread
    # count comes from that variable (Rakefile, top).
    local shim
    shim="$(write_ruby_shim)"
    export RUBYOPT="-r$shim ${RUBYOPT:-}"

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
