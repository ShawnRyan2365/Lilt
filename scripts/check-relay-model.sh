#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --product LiltChecks
BIN_DIR="$(swift build --show-bin-path)"
# The app target is not a library, so its model sources are compiled here beside the checks, against LiltCore only.
# Encryption (LiltTransfer) stays out: the account-transfer checks below cover the plaintext transaction.
# Only the objects of LiltCore's current sources: a file moved out of the module leaves its old object behind.
CORE_OBJECTS=()
for source in Sources/LiltCore/*.swift; do CORE_OBJECTS+=("$BIN_DIR/LiltCore.build/$(basename "$source").o"); done
swiftc -parse-as-library -I "$BIN_DIR/Modules" \
  "${CORE_OBJECTS[@]}" \
  Sources/Lilt/AppModel.swift Sources/Lilt/SecureStorage.swift \
  Sources/Lilt/Services.swift Sources/Lilt/StatusLineBridge.swift Sources/Lilt/Updater.swift \
  Sources/Lilt/ProjectSupport.swift Sources/Lilt/ProjectStatusLineBridge.swift Sources/Lilt/AccountTransfer.swift \
  Sources/Lilt/Components.swift Sources/Lilt/Design/*.swift \
  Tests/LiltModelTests/*.swift -o "$BIN_DIR/LiltModelChecks"
# The live-model checks write Lilt's own files under the home directory, so it points at a fixture under work/.
FIXTURE_HOME="$PWD/work/model-home-$$"
mkdir -p "$FIXTURE_HOME"
trap 'rm -rf "$FIXTURE_HOME"' EXIT
CFFIXED_USER_HOME="$FIXTURE_HOME" "$BIN_DIR/LiltModelChecks"
