#!/usr/bin/env bash
# Builds YTV1.framework (ios-arm64) into modules/ytv1 from famomatic/ytv1 and the
# bridge in ytv1bridge/. Go cannot emit an iOS shared library directly, so the
# bridge is built as a c-archive and linked into a dylib with clang.
# It is never linked into YouMod: Files/YTV1Download.x dlopens it on first use.
#
#   YTV1_REF   ytv1 branch/tag to build (default: main)
#   SDKROOT    iPhoneOS SDK (default: xcrun's, or $THEOS/sdks/iPhoneOS*.sdk)
# Missing Go or a failed build is not fatal: YouMod then builds without the
# ytv1 download method.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
OUT_DIR="$ROOT/modules/ytv1"
REF="${YTV1_REF:-main}"

warn() { printf '\033[33mwarning:\033[0m %s\n' "$*" >&2; }

command -v go >/dev/null 2>&1 || { warn "go not found - building without ytv1"; exit 0; }

sdk="${SDKROOT:-}"
if [[ -z "$sdk" ]] && command -v xcrun >/dev/null 2>&1; then sdk="$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null || true)"; fi
if [[ -z "$sdk" && -n "${THEOS:-}" ]]; then sdk="$(ls -d "$THEOS"/sdks/iPhoneOS*.sdk 2>/dev/null | sort -V | tail -n 1 || true)"; fi
[[ -n "$sdk" && -d "$sdk" ]] || { warn "no iPhoneOS SDK found - building without ytv1"; exit 0; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
if ! git clone --quiet --depth=1 --branch "$REF" https://github.com/famomatic/ytv1.git "$tmp/ytv1"; then
  warn "could not clone famomatic/ytv1@$REF - building without ytv1"
  exit 0
fi
commit="$(git -C "$tmp/ytv1" rev-parse --short HEAD)"
mkdir -p "$tmp/ytv1/mobile/ytv1ios"
cp "$ROOT"/ytv1bridge/*.go "$tmp/ytv1/mobile/ytv1ios/"

cat > "$tmp/cc" <<CC
#!/bin/sh
exec clang -target arm64-apple-ios14.0 -isysroot "$sdk" -Wno-unused-command-line-argument "\$@"
CC
chmod +x "$tmp/cc"

# Apple's ld on macOS, lld elsewhere (a plain string: macOS bash 3.2 treats an
# empty array as unbound under set -u)
linker_flag=""
[[ "$(uname)" == "Darwin" ]] || linker_flag="-fuse-ld=lld"

(
  cd "$tmp/ytv1"
  GOOS=ios GOARCH=arm64 CGO_ENABLED=1 CC="$tmp/cc" \
    go build -trimpath -buildmode=c-archive \
      -ldflags "-s -w -X main.ytv1Commit=$commit" \
      -o "$tmp/libytv1.a" ./mobile/ytv1ios
)
# Index the archive with an Apple-aware ranlib (GNU ranlib skips Mach-O objects)
if [[ "$(uname)" == "Darwin" ]]; then xcrun ranlib "$tmp/libytv1.a" 2>/dev/null || ranlib "$tmp/libytv1.a"
else llvm-ranlib "$tmp/libytv1.a"; fi

fw="$tmp/YTV1.framework"
mkdir -p "$fw"
"$tmp/cc" $linker_flag -dynamiclib -o "$fw/YTV1" \
  -Wl,-all_load "$tmp/libytv1.a" \
  -framework CoreFoundation -framework Security -lresolv \
  -install_name @rpath/YTV1.framework/YTV1
cat > "$fw/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>YTV1</string>
	<key>CFBundleIdentifier</key><string>io.github.famomatic.ytv1</string>
	<key>CFBundleName</key><string>YTV1</string>
	<key>CFBundlePackageType</key><string>FMWK</string>
	<key>CFBundleShortVersionString</key><string>1.0</string>
	<key>CFBundleVersion</key><string>$commit</string>
	<key>CFBundleSupportedPlatforms</key><array><string>iPhoneOS</string></array>
	<key>MinimumOSVersion</key><string>14.0</string>
</dict>
</plist>
PLIST

# Ad-hoc signature so a jailbroken device can load it from the deb (sideloading
# signers re-sign it anyway).
ldid_bin="$(command -v ldid || true)"
[[ -z "$ldid_bin" && -n "${THEOS:-}" ]] && ldid_bin="$(ls "$THEOS"/toolchain/*/iphone/bin/ldid 2>/dev/null | head -n 1 || true)"
if [[ -n "$ldid_bin" ]]; then "$ldid_bin" -S "$fw/YTV1"
elif command -v codesign >/dev/null 2>&1; then codesign --force --sign - "$fw/YTV1"
else warn "no ldid/codesign - YTV1 left unsigned"; fi

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"
cp -R "$fw" "$OUT_DIR/"
echo "ytv1 $commit:"
ls -lh "$OUT_DIR/YTV1.framework"
