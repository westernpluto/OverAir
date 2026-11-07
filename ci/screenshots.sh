#!/usr/bin/env bash
# Boots iPhone + iPhone Duo simulators, points OverAir at the mock HDHomeRun, and screenshots each screen.
set -uo pipefail
OUT="$PWD/build/screenshots"
mkdir -p "$OUT"
APP=build/sim/Build/Products/Debug-iphonesimulator/OverAir.app
# Apple-silicon simulators only run signed arm64 code: ad-hoc sign the unsigned build.
codesign --force --deep --sign - "$APP"
python3 ci/mock_hdhomerun.py ci/media 5004 > "$OUT/mock-server.log" 2>&1 &
sleep 2
curl -s http://127.0.0.1:5004/discover.json | head -c 120; echo

RUNTIME=$(xcrun simctl list runtimes -j | python3 -c 'import json,sys; r=[x for x in json.load(sys.stdin)["runtimes"] if x["platform"]=="iOS" and x["isAvailable"]]; print(sorted(r,key=lambda x:[int(p) for p in x["version"].split(".")])[-1]["identifier"])')
echo "Runtime: $RUNTIME"

# Exact device-type name → identifier, trying candidates in order.
pick() {
  xcrun simctl list devicetypes -j | python3 -c "import json,sys
types={d['name']:d['identifier'] for d in json.load(sys.stdin)['devicetypes']}
for n in sys.argv[1:]:
    if n in types: print(types[n]); break" "$@"
}

shoot() { # udid, file-prefix
  local udid=$1 prefix=$2
  if ! xcrun simctl io "$udid" screenshot "$prefix.png" > /dev/null 2>&1; then
    for d in 1 2; do xcrun simctl io "$udid" screenshot --display="$d" "$prefix-display$d.png" > /dev/null 2>&1 || true; done
  fi
}

launch() { # udid, scenario, log
  SIMCTL_CHILD_OVERAIR_DEVICE=127.0.0.1:5004 \
  SIMCTL_CHILD_OVERAIR_API_BASE=http://127.0.0.1:5004/api \
  SIMCTL_CHILD_OVERAIR_CLOUD_DISCOVER=http://127.0.0.1:5004/discover \
  SIMCTL_CHILD_OVERAIR_SCENARIO=$2 \
    xcrun simctl launch --terminate-running-process --stdout="$3" --stderr="$3" "$1" com.overair.app > /dev/null 2>> "$OUT/launch-errors.txt"
}

SCENARIOS="live player player-tips player-mini guide recordings search settings multiview"
for entry in "iphone:iPhone 18 Pro:iPhone 17 Pro:iPhone 17" "duo:iPhone Duo"; do
  TAG=${entry%%:*}
  IFS=':' read -r -a NAMES <<< "${entry#*:}"
  TYPE=$(pick "${NAMES[@]}")
  if [ -z "$TYPE" ]; then echo "No device type for $TAG"; continue; fi
  echo "== $TAG ($TYPE)"
  UDID=$(xcrun simctl create "shots-$TAG" "$TYPE" "$RUNTIME") || { echo "create failed"; continue; }
  xcrun simctl boot "$UDID"
  xcrun simctl bootstatus "$UDID" -b > /dev/null
  xcrun simctl io "$UDID" enumerate > "$OUT/$TAG-displays.txt" 2>&1 || true
  xcrun simctl status_bar "$UDID" override --time "9:41" --batteryState charged --batteryLevel 100 --wifiBars 3 > /dev/null 2>&1 || true
  xcrun simctl install "$UDID" "$APP"
  for S in $SCENARIOS; do
    launch "$UDID" "$S" "$OUT/$TAG-$S.log"
    sleep 12
    shoot "$UDID" "$OUT/$TAG-$S"
    echo "  $S"
  done
  xcrun simctl ui "$UDID" content_size accessibility-medium > /dev/null 2>&1 || true
  for S in live player; do
    launch "$UDID" "$S" "$OUT/$TAG-$S-largetext.log"
    sleep 12
    shoot "$UDID" "$OUT/$TAG-$S-largetext"
  done
  xcrun simctl shutdown "$UDID"
done
ls -la "$OUT"
