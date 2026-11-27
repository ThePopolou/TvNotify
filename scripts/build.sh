#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
STAGE_DIR="$DIST_DIR/.stage"

rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR" "$STAGE_DIR"

echo "==> Validating Lua syntax..."
luac -p "$ROOT_DIR/drivers/common/tvnotify_common.lua"
luac -p "$ROOT_DIR/drivers/tvnotify_controller/driver.lua"
luac -p "$ROOT_DIR/drivers/tvnotify_android_tv/driver.lua"

echo "==> Validating XML..."
xmllint --noout "$ROOT_DIR/drivers/tvnotify_controller/driver.xml"
xmllint --noout "$ROOT_DIR/drivers/tvnotify_android_tv/driver.xml"

build_c4z() {
    local name="$1"
    local src="$ROOT_DIR/drivers/$name"
    local stage="$STAGE_DIR/$name"
    mkdir -p "$stage"
    cp -R "$src/." "$stage/"
    cp "$ROOT_DIR/drivers/common/tvnotify_common.lua" "$stage/tvnotify_common.lua"
    (cd "$stage" && zip -q -r "$DIST_DIR/${name}.c4z" .)
    echo "    Built $DIST_DIR/${name}.c4z"
}

echo "==> Packaging .c4z drivers..."
build_c4z "tvnotify_controller"
build_c4z "tvnotify_android_tv"

VERSION="$(grep -m1 'DRIVER_VERSION' "$ROOT_DIR/drivers/tvnotify_controller/driver.lua" | sed -E 's/.*"([^"]+)".*/\1/')"
(cd "$DIST_DIR" && zip -q "TvNotify_v${VERSION}.zip" tvnotify_controller.c4z tvnotify_android_tv.c4z)
rm -rf "$STAGE_DIR"

echo "==> Built $DIST_DIR/TvNotify_v${VERSION}.zip"
