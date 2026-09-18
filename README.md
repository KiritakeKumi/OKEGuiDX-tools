# OKEGuiDX-tools

Automated builds of every external tool OKEGuiDX drives, for all five target
platforms. See `PLAN.md` and `TOOLS-REPO.md` in the main repository for the
design rationale.

## Targets

| target | runner | toolchain |
|---|---|---|
| `win-x64` | ubuntu-latest | llvm-mingw `x86_64-w64-mingw32` |
| `win-arm64` | ubuntu-latest | llvm-mingw `aarch64-w64-mingw32` |
| `linux-x64` | ubuntu-latest (Alpine container) | musl, fully static |
| `linux-arm64` | ubuntu-24.04-arm | native |
| `linux-riscv64` | ubuntu-latest | riscv64 cross toolchain, QEMU for smoke tests |

## Tools

| tool | notes |
|---|---|
| x264 | tmod fork on win-x64, upstream elsewhere |
| x265 | Asuna fork on win-x64, upstream 4.x elsewhere |
| SVT-AV1 | upstream |
| ffmpeg | **without** `--enable-libfdk-aac` (licence and quality policy) |
| mkvtoolnix | `mkvmerge`/`mkvextract` only, `--enable-qt=no` |
| l-smash | the simplest tool, used to validate the CI skeleton |
| flac | audio pipeline |

## Usage

```sh
# Build one tool for one target.
./scripts/build.sh x265 linux-arm64

# Build the Asuna variant of x265 for win-x64.
./scripts/build.sh x265 win-x64 asuna

# Check that the results actually run.
./scripts/smoke.sh linux-x64

# Package a target's output for consumption by OKEGuiDX.
./scripts/bundle.sh linux-x64
```

Recipes are plain shell scripts exporting `fetch`, `configure`, `build` and
`install`. There is deliberately no build framework: a recipe must be readable
and debuggable by hand.

## Versioning

`versions.lock` is the only place a version is recorded. CI rebuilds a tool only
when its entry changes. Bumping a version is a one-line edit.

## Licence compliance

x264, x265 and ffmpeg are GPL-licensed. Because this repository publishes their
binaries, the corresponding source must be obtainable:

- `versions.lock` records the **exact tag or commit** of every build.
- Every bundle ships `SOURCES.md` and `LICENSES/versions.lock`.
- Any patch a recipe applies lives in `patches/` and is part of the source.

`ffmpeg` is deliberately built **without** `--enable-libfdk-aac`: that licence is
incompatible with GPL redistribution, and the engine refuses AAC encoding on
platforms without qaac anyway.
