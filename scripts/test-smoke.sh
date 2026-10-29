#!/usr/bin/env bash
# Exercise artifact completeness and process failures without real encoders.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/scripts" "$fixture/targets" "$fixture/bin"
cp "$ROOT/scripts/smoke.sh" "$fixture/scripts/"
cat > "$fixture/bin/uname" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in -s) echo MINGW64_NT ;; -m) echo x86_64 ;; esac
SH
cat > "$fixture/bin/qemu-riscv64" <<'SH'
#!/usr/bin/env bash
[[ "$1" == -L ]] && shift 2
exec "$@"
SH
cp "$fixture/bin/qemu-riscv64" "$fixture/bin/qemu-aarch64"
chmod +x "$fixture/bin/"*
export PATH="$fixture/bin:$PATH"
common=(x26x/x264 x26x/x265 svtav1/SvtAv1EncApp ffmpeg/ffmpeg
        ffmpeg/ffprobe mkvtoolnix/mkvmerge mkvtoolnix/mkvextract
        l-smash/muxer l-smash/remuxer flac/flac)
write_ok() {
    printf '#!/usr/bin/env bash\necho fixture-version\n' > "$1"
    chmod +x "$1"
}
checks=0
expect() {
    local expected="$1" target="$2" message="$3" code=0
    bash "$fixture/scripts/smoke.sh" "$target" > "$fixture/log" 2>&1 || code=$?
    if [[ "$code" != "$expected" ]] || ! grep -qF "$message" "$fixture/log"; then
        cat "$fixture/log" >&2
        echo "unexpected result for $target: exit $code, wanted $expected / $message" >&2
        exit 1
    fi
    checks=$((checks + 1))
}
for target in linux-x64 linux-arm64 linux-riscv64 win-x64 win-arm64; do
    echo 'EXE_SUFFIX=' > "$fixture/targets/$target.env"
    base="$fixture/out/$target/tools"
    bins=("${common[@]}")
    [[ "$target" != win-x64 ]] || bins+=(x26x/x264-tmod x26x/x265-asuna x26x/x265-kyouko)
    for bin in "${bins[@]}"; do
        mkdir -p "$(dirname "$base/$bin")"
        write_ok "$base/$bin"
    done
    expect 0 "$target" "all ${#bins[@]} smoke tests passed"
    # Losing even one artifact must fail although the rest are runnable.
    for missing in x26x/x265 l-smash/remuxer; do
        rm "$base/$missing"
        expect 1 "$target" 'required binary missing'
        write_ok "$base/$missing"
    done
    printf '#!/usr/bin/env bash\necho encoder-failed >&2\nexit 7\n' > "$base/x26x/x265"
    expect 1 "$target" 'encoder-failed'
    # Long version output must be consumed before checking the exit status.
    printf '#!/usr/bin/env bash\nfor ((i=0;i<10000;i++)); do echo verbose-version; done\n' > "$base/x26x/x265"
    expect 0 "$target" "all ${#bins[@]} smoke tests passed"
done
echo "$checks smoke regression cases passed"
