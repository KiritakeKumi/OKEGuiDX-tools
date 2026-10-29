# OKEGuiDX-tools

Build recipes for OKEGuiDX open-source external tools across five targets. VapourSynth/vspipe, qaac and eac3to are supplied separately. Internal planning documents are not shipped in the public repositories.

## Targets

| target | build runner | toolchain |
|---|---|---|
| `win-x64` | ubuntu-latest | llvm-mingw `x86_64-w64-mingw32` |
| `win-arm64` | ubuntu-latest | llvm-mingw `aarch64-w64-mingw32` |
| `linux-x64` | ubuntu-latest (Alpine container) | musl, fully static |
| `linux-arm64` | ubuntu-24.04-arm | native |
| `linux-riscv64` | ubuntu-24.04 | GCC/G++ 14 cross toolchain, QEMU for smoke tests |

## Smoke tests and current status (2026-10-30)

Smoke tests are jobs in build.yml. win-arm64 runs on native windows-11-arm; linux-arm64/riscv64 use QEMU on x86 Linux, win-x64 uses Wine and linux-x64 executes directly. linux-riscv64 currently uses GNU/glibc, not musl.

The [previous run at 08ca677](https://github.com/KiritakeKumi/OKEGuiDX-tools/actions/runs/36913310070) has 41 successful jobs, one failure and two cancellations. x265 upstream / linux-riscv64 failed during Build. linux-x64/win-x64 smoke jobs were cancelled during emulator installation. The other three smoke jobs passed.

That run allowed missing binaries to be skipped, so its riscv64 smoke success did not validate x265. Its build log confirms the vxrm patch applied, followed by an RVV intrinsic argument mismatch with GCC 13.

The current changes select GCC/G++ 14 for riscv64, install emulators only where needed, and make every required binary mandatory, including l-smash remuxer. Windows x64 additionally requires the encoder variants. Each smoke job downloads only its target artifacts and has a 20-minute limit. All 25 fixture-based smoke regression cases pass locally and run in CI; a new full build and real-tool smoke run is still required for acceptance. RVV encoding comparisons remain pending. The next CI run also exposed runner CMake 4 rejecting legacy x265 policies; Ubuntu x265 jobs now explicitly use CMake 3.31.6. l-smash receives the selected compiler suffix so its cross-prefix logic also respects GCC 14.

bundle.sh packages local output; automated bundle/Release is not implemented.

## Tools

| tool | notes |
|---|---|
| x264 | tmod fork on win-x64, upstream elsewhere |
| x265 | win-x64 builds Kyouko (engine default), Asuna and upstream; other targets use upstream 4.2 |
| SVT-AV1 | upstream |
| ffmpeg | **without** `--enable-libfdk-aac` (licence and quality policy) |
| mkvtoolnix | v58.0.0, Qt-free CLI; `mkvmerge`/`mkvextract` only |
| l-smash | the simplest tool, used to validate the CI skeleton |
| flac | audio pipeline |

## Usage

```sh
# Build one tool for one target. The variant is required when versions.lock
# lists more than one build of a tool; it is the fourth column.
./scripts/build.sh x265 linux-arm64 upstream
./scripts/build.sh x264 linux-arm64 upstream

# Build the Asuna variant of x265 for win-x64.
./scripts/build.sh x265 win-x64 asuna

# Check that the results actually run.
./scripts/smoke.sh linux-x64

# Package a target's output for consumption by OKEGuiDX.
./scripts/bundle.sh linux-x64
```

`build.sh` looks a tool up in `versions.lock` by tool name *and* variant, so the
variant argument must match that file exactly. Omitting it fails with a clear
"no entry" message rather than silently picking one.

Recipes are plain shell scripts exporting `fetch`, `configure`, `build` and
`install`. There is deliberately no build framework: a recipe must be readable
and debuggable by hand.

## Versioning

versions.lock records pinned versions and target allow-lists. Matching changes to versions.lock, recipes, patches, targets, scripts or build.yml trigger the full matrix. Manual dispatch is also supported. CI does not select only changed tools.

## Licence compliance

x264, x265 and ffmpeg are GPL-licensed. Because this repository publishes their
binaries, the corresponding source must be obtainable:

- `versions.lock` records the **exact tag or commit** of every build.
- Every bundle ships `SOURCES.md` and `LICENSES/versions.lock`.
- Any patch a recipe applies lives in `patches/` and is part of the source.

`ffmpeg` is deliberately built **without** `--enable-libfdk-aac`: that licence is
incompatible with GPL redistribution, and the engine refuses AAC encoding on
platforms without qaac anyway.
