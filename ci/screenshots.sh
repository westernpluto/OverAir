#!/usr/bin/env bash
# Boots iPhone + iPhone Duo simulators, points OverAir at the mock HDHomeRun, and screenshots each screen.
set -uo pipefail
OUT=build/screenshots
mkdir -p "$OUT"
APP=build/sim/Build/Products/Debug-iphonesimulator/OverAir.app
# Apple-silicon simulators only run signed arm64 code: ad-hoc sign the unsigned build.
codesign --force --deep --sign - "$APP"
python3 ci/mock_hdhomerun.py ci/media 5004 > "$OUT/mock-server.log" 2>&1 &
sleep 2
curl -s http://127.0.0.1:5004/discover.json | head -c 200; echo

xcrun simctl help > "$OUT/simctl-help.txt" 2>&1
xcrun simctl help io > "$OUT/simctl-help-io.txt" 2>&1
xcrun simctl help ui > "$OUT/simctl-help-ui.txt" 2>&1
xcrun simctl list devicetypes > "$OUT/devicetypes.txt"
RUNTIME=$(xcrun simctl list runtimes -j | python3 -c 'import json,sys; r=[x for x in json.load(sys.stdin)["runtimes"] if x["platform"]=="iOS" and x["isAvailable"]]; print(sorted(r,key=lambda x:[int(p) for p in x["version"].split(".")])[-1]["identifier"])')
echo "Runtime: $RUNTIME"

pick() { xcrun simctl list devicetypes -j | python3 -c "import json,sys
t=[d for d in json.load(sys.stdin)['devicetypes'] if '$1'.lower() in d['name'].lower()]
print(t[-1]['identifier'] if t else '')"; }

DEVICES=("iPhone 17 Pro:iphone" "iPhone Duo:duo")
SCENARIOS="live player player-tips player-mini guide recordings search settings multiview"

for entry in "${DEVICES[@]}"; do
  NAME=${entry%%:*}; TAG=${entry##*:}
  TYPE=$(pick "$NAME")
  [ -z "$TYPE" ] && TYPE=$(pick "iPhone")
  echo "== $TAG ($TYPE)"
  UDID=$(xcrun simctl create "shots-$TAG" "$TYPE" "$RUNTIME")
  xcrun simctl boot "$UDID"
  xcrun simctl bootstatus "$UDID" -b > /dev/null
  xcrun simctl status_bar "$UDID" override --time "9:41" --batteryState charged --batteryLevel 100 --wifiBars 3 || true
  xcrun simctl install "$UDID" "$APP"
  for S in $SCENARIOS; do
    SIMCTL_CHILD_OVERAIR_DEVICE=127.0.0.1:5004 \
    SIMCTL_CHILD_OVERAIR_API_BASE=http://127.0.0.1:5004/api \
    SIMCTL_CHILD_OVERAIR_CLOUD_DISCOVER=http://127.0.0.1:5004/discover \
    SIMCTL_CHILD_OVERAIR_SCENARIO=$S \
      xcrun simctl launch --terminate-running-process --stdout="$OUT/$TAG-$S.log" --stderr="$OUT/$TAG-$S.log" "$UDID" com.overair.app > /dev/null
    sleep 12
    xcrun simctl io "$UDID" screenshot "$OUT/$TAG-$S.png" 2>&1 | tail -1
    echo "  $S"
  done
  # Larger text, to check Dynamic Type scaling.
  xcrun simctl ui "$UDID" content_size accessibility-medium || true
  for S in live player; do
    SIMCTL_CHILD_OVERAIR_DEVICE=127.0.0.1:5004 SIMCTL_CHILD_OVERAIR_API_BASE=http://127.0.0.1:5004/api \
    SIMCTL_CHILD_OVERAIR_CLOUD_DISCOVER=http://127.0.0.1:5004/discover SIMCTL_CHILD_OVERAIR_SCENARIO=$S \
      xcrun simctl launch --terminate-running-process "$UDID" com.overair.app > /dev/null
    sleep 12
    xcrun simctl io "$UDID" screenshot "$OUT/$TAG-$S-largetext.png" 2>&1 | tail -1
  done
  xcrun simctl ui "$UDID" content_size medium || true
  xcrun simctl spawn "$UDID" log show --last 6m --predicate 'process == "OverAir"' --style compact > "$OUT/$TAG-system.log" 2>&1 || true
  xcrun simctl shutdown "$UDID"
done
ls -la "$OUT"
