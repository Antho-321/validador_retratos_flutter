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
ADB_BIN="${ADB_BIN:-adb}"
ADB_REVERSE="${ADB_REVERSE:-1}"

if [[ "$ADB_REVERSE" == "1" ]]; then
  if command -v "$ADB_BIN" >/dev/null 2>&1; then
    if command -v timeout >/dev/null 2>&1; then
      timeout 5 "$ADB_BIN" -s "$DEVICE_ID" reverse tcp:3000 tcp:3000 || true
      timeout 5 "$ADB_BIN" -s "$DEVICE_ID" reverse tcp:5001 tcp:5001 || true
    else
      "$ADB_BIN" -s "$DEVICE_ID" reverse tcp:3000 tcp:3000 || true
      "$ADB_BIN" -s "$DEVICE_ID" reverse tcp:5001 tcp:5001 || true
    fi
  fi
fi

exec "$FLUTTER_BIN" run \
  -d "$DEVICE_ID" \
  --no-pub \
  --no-track-widget-creation \
  --android-skip-build-dependency-validation \
  "$@"
