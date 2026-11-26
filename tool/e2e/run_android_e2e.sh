#!/usr/bin/env bash
# Runs one Android E2E acceptance scenario on an already-booted device, records
# the screen, and collects screenshots, video, logcat and a failure screenshot.
#
# CI: .github/workflows/e2e-android.yml calls this inside
# `reactivecircus/android-emulator-runner`'s `script:` with the step env in
# place. The test APK is prebuilt by the workflow so the drive invocation stays
# inside screenrecord's 180 s cap.
#
# Local (use a disposable emulator, not your phone):
#   flutter pub get --enforce-lockfile
#   flutter build apk --debug --target-platform=android-x64 \
#     --target=integration_test/e2e/example_acceptance_test.dart
#   E2E_TARGET=integration_test/e2e/example_acceptance_test.dart \
#     E2E_TEST_APK=build/app/outputs/flutter-apk/app-debug.apk \
#     bash tool/e2e/run_android_e2e.sh
# Then look at build/e2e/screenshots and build/e2e/video.
#
# On an arm64 emulator build with --target-platform=android-arm64 instead.
# The script never touches a physical device's app data: the clear/stay-awake
# block only runs for `emulator-*` serials unless E2E_CLEAR_APP_DATA=1.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

DEVICE="${E2E_DEVICE:-emulator-5554}"
OUTPUT="${E2E_OUTPUT:-build/e2e}"
TARGET="${E2E_TARGET:?set E2E_TARGET to the acceptance scenario to drive}"
DRIVER="${E2E_DRIVER:-test_driver/e2e_review.dart}"
TEST_APK="${E2E_TEST_APK:-build/e2e/e2e-test-x64.apk}"
PACKAGE="${E2E_ANDROID_PACKAGE:-com.cuplivo.cuplivo}"
VIDEO_SECONDS="${E2E_VIDEO_SECONDS:-180}"
VIDEO_DEVICE_PATH="${E2E_VIDEO_DEVICE_PATH:-/data/local/tmp/cuplivo-e2e.mp4}"
DRIVE_TIMEOUT="${E2E_DRIVE_TIMEOUT_SECONDS:-420}"

SCREENSHOTS="$OUTPUT/screenshots"
FAILURES="$OUTPUT/failure-screenshots"
VIDEO_DIR="$OUTPUT/video"
LOGS="$OUTPUT/logs"
mkdir -p "$SCREENSHOTS" "$FAILURES" "$VIDEO_DIR" "$LOGS"

log() { printf 'e2e: %s\n' "$*"; }
adb_s() { adb -s "$DEVICE" "$@"; }

# --- wait for the emulator -------------------------------------------------
log "waiting for $DEVICE"
if ! timeout 180 adb -s "$DEVICE" wait-for-device; then
  log "no device $DEVICE"
  exit 1
fi
for _ in $(seq 1 300); do
  if [ "$(adb_s shell getprop sys.boot_completed 2>/dev/null | tr -d '\r\n')" = "1" ]; then
    break
  fi
  sleep 1
done
if [ "$(adb_s shell getprop sys.boot_completed 2>/dev/null | tr -d '\r\n')" != "1" ]; then
  log "device did not report sys.boot_completed=1"
  adb_s exec-out screencap -p > "$FAILURES/device-not-booted.png" 2>/dev/null || true
  exit 1
fi

# A reused AVD keeps the previous run's app data; the seeded database is
# per-run, but clearing keeps startup probes and preferences deterministic.
case "${E2E_CLEAR_APP_DATA:-auto}" in
  1) disposable=1 ;;
  0) disposable=0 ;;
  *) if [ "${DEVICE#emulator-}" != "$DEVICE" ]; then disposable=1; else disposable=0; fi ;;
esac
if [ "$disposable" = 1 ]; then
  adb_s shell wm dismiss-keyguard >/dev/null 2>&1 || true
  adb_s shell settings put global stay_on_while_plugged_in 3 >/dev/null 2>&1 || true
  adb_s shell pm clear "$PACKAGE" >/dev/null 2>&1 || true
fi

# --- logs ------------------------------------------------------------------
adb_s logcat -c >/dev/null 2>&1 || true
adb_s logcat > "$LOGS/logcat.txt" 2>&1 &
LOGCAT_PID=$!

# --- screen recording ------------------------------------------------------
# screenrecord caps each file at 180 s and records no audio. The drive run
# starts from a prebuilt APK specifically so it fits; a longer run truncates
# the video, it does not fail the job.
# Write under /data/local/tmp, not /sdcard: at boot the emulator's storage
# service can reject shell writes to /sdcard with EPERM even though the
# framework reports boot_completed, which silently lost the recording.
record_mode="device"
# The framework reports boot_completed before /sdcard and the media service are
# necessarily usable; starting screenrecord immediately can lose the recorder.
sleep 2
record_pid=""
video_file=""
rm -f "$VIDEO_DIR"/*.mp4 "$VIDEO_DIR"/*.webm 2>/dev/null || true
if adb_s shell 'ls /system/bin/screenrecord >/dev/null 2>&1'; then
  adb_s shell rm -f "$VIDEO_DEVICE_PATH" >/dev/null 2>&1 || true
  adb_s shell screenrecord \
    --bit-rate 6000000 \
    --time-limit "$VIDEO_SECONDS" \
    "$VIDEO_DEVICE_PATH" > "$LOGS/screenrecord.log" 2>&1 &
  record_pid=$!
  export E2E_RECORD_START_EPOCH="$(date +%s)"
  # Give the recorder time to appear in the process table. A missing pid is a
  # warning, not a verdict: the old code marked the run video-less on a slow
  # start and threw away a recording that was about to work.
  sleep 3
  if ! adb_s shell pidof screenrecord >/dev/null 2>&1; then
    log "screenrecord process not visible yet; keeping device mode and trying to pull"
  fi
else
  # Documented emulator-console fallback (WebM on the host). It needs a
  # display, so it is only a best effort on headless CI.
  log "device screenrecord is unavailable; trying the emulator console recorder"
  export E2E_RECORD_START_EPOCH="$(date +%s)"
  if adb_s emu screenrecord start --time-limit "$VIDEO_SECONDS" "$ROOT/$VIDEO_DIR/e2e.webm" >/dev/null 2>&1; then
    record_mode="emulator"
  else
    log "no recorder available; continuing without video"
    record_mode="none"
  fi
fi

# --- the acceptance scenario -----------------------------------------------
log "using target: $TARGET"
log "using driver: $DRIVER"
status=0
if [ -f "$TEST_APK" ]; then
  log "using prebuilt test APK: $TEST_APK"
  flutter drive \
    --driver="$DRIVER" \
    --target="$TARGET" \
    --use-application-binary="$TEST_APK" \
    -d "$DEVICE" \
    --no-pub \
    --screenshot "$FAILURES" \
    --timeout "$DRIVE_TIMEOUT" \
    2>&1 | tee "$LOGS/flutter-drive.log"
  status=${PIPESTATUS[0]}
else
  # Local fallback: let flutter drive build the test app. Slower, so the video
  # will usually stop at its cap before the run ends.
  log "no prebuilt APK at $TEST_APK; flutter drive will build the test app"
  flutter drive \
    --driver="$DRIVER" \
    --target="$TARGET" \
    -d "$DEVICE" \
    --screenshot "$FAILURES" \
    --timeout "$DRIVE_TIMEOUT" \
    2>&1 | tee "$LOGS/flutter-drive.log"
  status=${PIPESTATUS[0]}
fi

# --- collect ---------------------------------------------------------------
export E2E_RECORD_END_EPOCH="$(date +%s)"
case "$record_mode" in
  device)
    if ! adb_s shell 'pkill -INT screenrecord' >/dev/null 2>&1; then
      adb_s shell 'kill -INT $(pidof screenrecord)' >/dev/null 2>&1 || true
    fi
    sleep 2
    kill "$record_pid" >/dev/null 2>&1 || true
    wait "$record_pid" 2>/dev/null || true
    if adb_s pull "$VIDEO_DEVICE_PATH" "$VIDEO_DIR/e2e.mp4" >/dev/null 2>&1; then
      video_file="e2e.mp4"
      log "video: $VIDEO_DIR/e2e.mp4"
    else
      log "video: no recording pulled"
    fi
    ;;
  emulator)
    adb_s emu screenrecord stop >/dev/null 2>&1 || true
    if [ -f "$VIDEO_DIR/e2e.webm" ]; then
      video_file="e2e.webm"
      log "video: $VIDEO_DIR/e2e.webm"
    else
      log "video: emulator recorder produced no file"
    fi
    ;;
  *)
    log "video: none"
    ;;
esac

if [ "$status" -ne 0 ]; then
  log "acceptance scenario failed (exit $status); capturing a device screenshot"
  adb_s exec-out screencap -p > "$FAILURES/device-failure.png" 2>/dev/null || true
fi

# A device-side crash shows up as a missing screenshot set, not as a Flutter
# assertion; keep the tail with the artifacts.
adb_s logcat -d -t 2000 > "$LOGS/logcat-tail.txt" 2>/dev/null || true
kill "$LOGCAT_PID" >/dev/null 2>&1 || true
wait "$LOGCAT_PID" 2>/dev/null || true

printf '{"recordStartEpoch":%s,"recordEndEpoch":%s,"mode":"%s","video":"%s"}\n' \
  "${E2E_RECORD_START_EPOCH:-0}" \
  "${E2E_RECORD_END_EPOCH:-0}" \
  "$record_mode" \
  "$video_file" > "$VIDEO_DIR/record.json"

log "screenshots: $(find "$SCREENSHOTS" -maxdepth 1 -name '*.png' | wc -l | tr -d ' ')"
log "done (acceptance scenario exit $status)"
exit "$status"
