#!/usr/bin/env bash
# Builds FFmpegKit (ffmpeg-kit-next) for iOS arm64 as the full GPL variant:
# --enable-gpl plus every external library the GPL policy allows
# (x264, x265, xvidcore, libvidstab, rubberband, lame, opus, vorbis, libvpx,
# dav1d, libaom, svt-av1, ...). Output: thin ios-arm64 .framework bundles in
# modules/ffmpeg, ready for tools/package-ffmpegkit.sh.
#
# Runs on macOS with Xcode 26 and Nix (the upstream-recommended toolchain: the
# "xcode26" Nix profile supplies every autotools/meson/cmake dependency the
# external libraries need). Takes hours the first time - CI runs it once via
# .github/workflows/ffmpegkit.yml and publishes the result as a release asset.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SRC_DIR="${FFMPEGKIT_SRC_DIR:-$ROOT/.cache/ffmpeg-kit-next}"
OUT_DIR="$ROOT/modules/ffmpeg"
REPO_URL="https://github.com/arthenica/ffmpeg-kit-next.git"
TAG="${FFMPEGKIT_TAG:-v9.0.0}"

FRAMEWORKS=(ffmpegkit libavcodec libavdevice libavfilter libavformat libavutil libswresample libswscale)

BUILD_ARGS=(
  --arch=arm64
  --xcframework
  --target=14.0
  --enable-gpl
  --enable-lib-all
  --enable-lib-ios-audiotoolbox
  --enable-lib-ios-avfoundation
  --enable-lib-ios-bzip2
  --enable-lib-ios-videotoolbox
  --enable-lib-ios-zlib
  --enable-lib-ios-libiconv
)

info() { printf '\033[36m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

command -v nix >/dev/null || die "nix is required (see ffmpeg-kit-next apple/README.md)"
command -v xcodebuild >/dev/null || die "Xcode is required"

if [[ ! -d "$SRC_DIR/.git" ]]; then
  info "cloning ffmpeg-kit-next $TAG"
  mkdir -p "$(dirname "$SRC_DIR")"
  git clone --quiet --depth=1 --branch "$TAG" "$REPO_URL" "$SRC_DIR"
fi

info "building FFmpegKit $TAG (full GPL, ios-arm64)"
(cd "$SRC_DIR" && ./nix-ios.sh -p xcode26 "${BUILD_ARGS[@]}") || {
  tail -n 200 "$SRC_DIR/build.log" >&2 || true
  die "ffmpeg-kit-next ios build failed"
}

XCF_DIR="$(find "$SRC_DIR/prebuilt" -maxdepth 1 -type d -name 'bundle-apple-xcframework-ios*' | sort | head -n 1)"
[[ -n "$XCF_DIR" ]] || die "no xcframework bundle under $SRC_DIR/prebuilt"

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"
for xcfw in "$XCF_DIR"/*.xcframework; do
  name="$(basename "$xcfw" .xcframework)"
  slice="$(find "$xcfw" -maxdepth 1 -type d -name 'ios-arm64' | head -n 1)"
  [[ -n "$slice" && -d "$slice/$name.framework" ]] || die "no ios-arm64 slice in $name.xcframework"
  cp -R "$slice/$name.framework" "$OUT_DIR/"
done

for fw in "$OUT_DIR"/*.framework; do
  name="$(basename "$fw" .framework)"
  bin="$fw/$name"
  [[ -f "$bin" ]] || continue
  # Lets the frameworks find each other when they sit together in any folder
  # (YouMod.bundle/Frameworks on jailbreak, YouTube.app/Frameworks in the IPA).
  install_name_tool -add_rpath "@loader_path/.." "$bin" 2>/dev/null || true
  codesign --force --sign - "$bin" >/dev/null
done

for f in "${FRAMEWORKS[@]}"; do
  [[ -f "$OUT_DIR/$f.framework/$f" ]] || die "missing $f.framework in build output"
done

cat > "$OUT_DIR/BUILDINFO" <<INFO
ffmpeg-kit-next $TAG
source: $REPO_URL
license: GPL-3.0 (built with --enable-gpl)
build_args: ${BUILD_ARGS[*]}
built: $(date -u +%Y-%m-%dT%H:%M:%SZ)
INFO

info "frameworks:"
du -sh "$OUT_DIR"/*.framework | sed 's/^/    /'
