#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
external_root='/Volumes/Samsung 4TB/Codex/tmp'
derived_data="${SCOUT_DERIVED_DATA_PATH:-$external_root/DerivedData/ScoutCapture-refactor}"
destination="${SCOUT_TEST_DESTINATION:-platform=iOS Simulator,name=iPhone 17 Pro}"

if [[ -z "${SCOUT_DERIVED_DATA_PATH:-}" && ! -d '/Volumes/Samsung 4TB' ]]; then
    printf 'Samsung 4TB is not mounted; set SCOUT_DERIVED_DATA_PATH to an approved external path.\n' >&2
    exit 1
fi

mkdir -p "$derived_data"
cd "$project_root"

xcodebuild test \
    -project ScoutCapture.xcodeproj \
    -scheme ScoutCapture \
    -destination "$destination" \
    -derivedDataPath "$derived_data" \
    -parallel-testing-enabled NO \
    -only-testing:ScoutCaptureTests/Phase2C27FZ4PropertyStatusDiagnosticsTests \
    -only-testing:ScoutCaptureTests/Phase2C10BSessionCoordinationTests \
    -only-testing:ScoutCaptureTests/Phase2C07bMediaBackfillTests \
    -only-testing:ScoutCaptureTests/Phase2C08CutoverTests \
    -only-testing:ScoutCaptureTests/Phase2C10OfflineReplayTests \
    -only-testing:ScoutCaptureTests/StoredZipArchiveTests \
    -only-testing:ScoutCaptureTests/TemporaryMigrationImportTests
