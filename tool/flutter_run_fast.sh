#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCAL_PROPS="$ROOT_DIR/android/local.properties"

FLUTTER_BIN="${FLUTTER_BIN:-}"
if [[ -z "$FLUTTER_BIN" && -f "$LOCAL_PROPS" ]]; then
  flutterSdk="$(sed -n 's/^flutter\\.sdk=//p' "$LOCAL_PROPS" | head -n 1)"
  if [[ -n "$flutterSdk" ]]; then
    FLUTTER_BIN="$flutterSdk/bin/flutter"
  fi
fi
FLUTTER_BIN="${FLUTTER_BIN:-flutter}"

DEVICE_ID="${DEVICE_ID:-SM A135M}"

exec "$FLUTTER_BIN" run \
  -d "$DEVICE_ID" \
  --no-pub \
  --no-track-widget-creation \
  --android-skip-build-dependency-validation \
  "$@"

