#!/usr/bin/env bash
# Downloads the prebuilt full-GPL FFmpegKit frameworks (published by
# .github/workflows/ffmpegkit.yml as a release asset) into modules/ffmpeg.
# Missing frameworks are not fatal: YouMod then builds without bundled FFmpeg
# and the downloader falls back to AVFoundation (H.264/AAC only).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
OUT_DIR="$ROOT/modules/ffmpeg"
REPO="${FFMPEGKIT_RELEASE_REPO:-${GITHUB_REPOSITORY:-famomatic/YouMod}}"
TAG="${FFMPEGKIT_RELEASE_TAG:-ffmpegkit-v9.0.0-full-gpl}"
ASSET="FFmpegKit-full-gpl-ios-arm64.zip"

warn() { printf '\033[33mwarning:\033[0m %s\n' "$*" >&2; }

if [[ -f "$OUT_DIR/ffmpegkit.framework/ffmpegkit" ]]; then
  echo "FFmpegKit already present in $OUT_DIR"
  exit 0
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
if ! gh release download "$TAG" --repo "$REPO" --pattern "$ASSET" --dir "$tmp" 2>"$tmp/err"; then
  warn "could not download $ASSET from $REPO release $TAG: $(cat "$tmp/err")"
  warn "building WITHOUT bundled FFmpegKit - run the 'Build FFmpegKit' workflow first"
  exit 0
fi

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"
ditto -x -k "$tmp/$ASSET" "$OUT_DIR" 2>/dev/null || unzip -q "$tmp/$ASSET" -d "$OUT_DIR"
echo "FFmpegKit frameworks:"
ls "$OUT_DIR"
