#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --product LiltChecks
BIN_DIR="$(swift build --show-bin-path)"
swiftc -parse-as-library -I "$BIN_DIR/Modules" \
  "$BIN_DIR"/LiltCore.build/*.swift.o \
  Sources/Lilt/AppModel.swift Sources/Lilt/SecureStorage.swift \
  Sources/Lilt/Services.swift Sources/Lilt/StatusLineBridge.swift Sources/Lilt/Updater.swift \
  Sources/Lilt/Components.swift Sources/Lilt/Design/*.swift \
  Tests/LiltModelTests/RelayModelChecks.swift -o "$BIN_DIR/LiltModelChecks"
# The live-model checks write Lilt's own files under the home directory, so it points at a fixture under work/.
FIXTURE_HOME="$PWD/work/model-home-$$"
mkdir -p "$FIXTURE_HOME"
trap 'rm -rf "$FIXTURE_HOME"' EXIT
CFFIXED_USER_HOME="$FIXTURE_HOME" "$BIN_DIR/LiltModelChecks"
