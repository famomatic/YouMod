#!/usr/bin/env bash
# Downloads MobileVLCKit (LGPL-2.1, VideoLAN's prebuilt release used by the
# CocoaPods spec) into modules/vlc/MobileVLCKit.framework, thinned to arm64 and
# without headers. It is never linked: the Downloads player dlopens it the first
# time a file needs the VLC route (formats AVFoundation can't decode).
# A failed download is not fatal: the player then offers conversion instead.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
OUT_DIR="$ROOT/modules/vlc"
VERSION="3.7.4"
URL="https://download.videolan.org/pub/cocoapods/prod/MobileVLCKit-3.0-20260922-1512.tar.xz"
SHA256="c649c4c47bd065b3a5511746361b5a9066a34033f2df9cbc9454409c0f363b52"

warn() { printf '\033[33mwarning:\033[0m %s\n' "$*" >&2; }

if [[ -f "$OUT_DIR/MobileVLCKit.framework/MobileVLCKit" ]]; then
  echo "MobileVLCKit already present in $OUT_DIR"
  exit 0
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
if ! curl -fsSL --retry 3 -o "$tmp/vlc.tar.xz" "$URL"; then
  warn "could not download MobileVLCKit $VERSION - building without the VLC playback route"
  exit 0
fi
actual="$(shasum -a 256 "$tmp/vlc.tar.xz" 2>/dev/null || sha256sum "$tmp/vlc.tar.xz")"
if [[ "${actual%% *}" != "$SHA256" ]]; then
  warn "MobileVLCKit checksum mismatch (${actual%% *}) - building without the VLC playback route"
  exit 0
fi
tar -xJf "$tmp/vlc.tar.xz" -C "$tmp"
src="$(find "$tmp" -type d -path '*ios-arm64_armv7_armv7s/MobileVLCKit.framework' -print -quit)"
if [[ -z "$src" ]]; then
  warn "MobileVLCKit.framework (device) not found in the archive"
  exit 0
fi

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR/MobileVLCKit.framework"
cp "$src/Info.plist" "$OUT_DIR/MobileVLCKit.framework/"
if command -v lipo >/dev/null 2>&1; then
  lipo "$src/MobileVLCKit" -thin arm64 -output "$OUT_DIR/MobileVLCKit.framework/MobileVLCKit"
else
  python3 - "$src/MobileVLCKit" "$OUT_DIR/MobileVLCKit.framework/MobileVLCKit" <<'PY'
import struct, sys
data = open(sys.argv[1], 'rb').read()
count = struct.unpack('>I', data[4:8])[0]
for i in range(count):
    cpu, sub, off, size, align = struct.unpack('>5I', data[8 + 20 * i:28 + 20 * i])
    if cpu == 0x0100000c:
        open(sys.argv[2], 'wb').write(data[off:off + size])
        break
else:
    sys.exit('no arm64 slice')
PY
fi
# VideoLAN ships it unsigned; an ad-hoc signature lets a jailbroken device load it
# from the deb (sideloading signers re-sign it anyway).
ldid_bin="$(command -v ldid || true)"
[[ -z "$ldid_bin" && -n "${THEOS:-}" ]] && ldid_bin="$(ls "$THEOS"/toolchain/*/iphone/bin/ldid 2>/dev/null | head -n 1 || true)"
if [[ -n "$ldid_bin" ]]; then "$ldid_bin" -S "$OUT_DIR/MobileVLCKit.framework/MobileVLCKit"; else warn "ldid not found - MobileVLCKit left unsigned"; fi
cp "$(dirname "$(dirname "$src")")/../COPYING.txt" "$OUT_DIR/MobileVLCKit.framework/COPYING.txt" 2>/dev/null || true
echo "MobileVLCKit $VERSION:"
ls -lh "$OUT_DIR/MobileVLCKit.framework"
