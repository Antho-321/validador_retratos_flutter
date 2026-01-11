#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCAL_PROPS="$ROOT_DIR/android/local.properties"

FLUTTER_BIN="${FLUTTER_BIN:-}"
if [[ -z "$FLUTTER_BIN" && -f "$LOCAL_PROPS" ]]; then
  flutterSdk="$(awk -F= '$1=="flutter.sdk" {print $2; exit}' "$LOCAL_PROPS")"
  if [[ -n "$flutterSdk" ]]; then
    FLUTTER_BIN="$flutterSdk/bin/flutter"
  fi
fi
FLUTTER_BIN="${FLUTTER_BIN:-flutter}"

RUN_PUB_GET="${RUN_PUB_GET:-1}"
PUBSPEC_FILE="$ROOT_DIR/pubspec.yaml"
LOCK_FILE="$ROOT_DIR/pubspec.lock"
PACKAGE_CONFIG="$ROOT_DIR/.dart_tool/package_config.json"

if [[ "$RUN_PUB_GET" == "1" ]]; then
  needs_pub_get=0
  if [[ ! -f "$PACKAGE_CONFIG" ]]; then
    needs_pub_get=1
  elif [[ -f "$PUBSPEC_FILE" && "$PUBSPEC_FILE" -nt "$PACKAGE_CONFIG" ]]; then
    needs_pub_get=1
  elif [[ -f "$LOCK_FILE" && "$LOCK_FILE" -nt "$PACKAGE_CONFIG" ]]; then
    needs_pub_get=1
  fi

  if [[ "$needs_pub_get" == "1" ]]; then
    "$FLUTTER_BIN" pub get
  fi
fi

DEVICE_ID="${DEVICE_ID:-SM A135M}"
ADB_BIN="${ADB_BIN:-adb}"
ADB_REVERSE="${ADB_REVERSE:-1}"
ADB_DEVICE_ID="${ADB_DEVICE_ID:-$DEVICE_ID}"

if [[ "$ADB_REVERSE" == "1" ]]; then
  if command -v "$ADB_BIN" >/dev/null 2>&1; then
    if ! "$ADB_BIN" devices | awk 'NR>1 {print $1}' | grep -Fxq "$ADB_DEVICE_ID"; then
      model_guess="${DEVICE_ID// /_}"
      resolved="$("$ADB_BIN" devices -l | awk -v model="model:$model_guess" '$0 ~ model {print $1; exit}')"
      if [[ -n "$resolved" ]]; then
        ADB_DEVICE_ID="$resolved"
      else
        ADB_DEVICE_ID=""
      fi
    fi

    if [[ -n "$ADB_DEVICE_ID" ]]; then
      if command -v timeout >/dev/null 2>&1; then
        timeout 5 "$ADB_BIN" -s "$ADB_DEVICE_ID" reverse tcp:3000 tcp:3000 || true
        timeout 5 "$ADB_BIN" -s "$ADB_DEVICE_ID" reverse tcp:5001 tcp:5001 || true
      else
        "$ADB_BIN" -s "$ADB_DEVICE_ID" reverse tcp:3000 tcp:3000 || true
        "$ADB_BIN" -s "$ADB_DEVICE_ID" reverse tcp:5001 tcp:5001 || true
      fi
    fi
  fi
fi

exec "$FLUTTER_BIN" run \
  -d "$DEVICE_ID" \
  --no-pub \
  --no-track-widget-creation \
  --android-skip-build-dependency-validation \
  "$@"
