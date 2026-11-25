#!/usr/bin/env bash
# Debug-simulator App Store frames. Not a release. Does not archive or upload
# to TestFlight. Requires Xcode and a 6.9-inch iPhone simulator.
set -euo pipefail

cd "$(dirname "$0")/.."

OUT="${SHOT_OUT:-artifacts/app-store-screenshots}"
DERIVED="${DERIVED_DATA:-${RUNNER_TEMP:-/tmp}/argus-screenshot-dd}"
RAW="$OUT/raw"
FRAMES="$OUT/frames"
mkdir -p "$RAW" "$FRAMES"

echo "Installing XcodeGen if needed"
if ! command -v xcodegen >/dev/null 2>&1; then
  brew install xcodegen
fi

echo "Generating the Xcode project"
xcodegen generate

echo "Building Debug for the simulator"
xcodebuild build \
  -project CryptoLedger.xcodeproj \
  -scheme CryptoLedger \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO

APP=$(find "$DERIVED/Build/Products" -path '*iphonesimulator*' -name '*.app' -type d | head -n 1)
if [[ -z "$APP" ]]; then
  echo "No simulator .app was produced" >&2
  exit 1
fi
echo "App: $APP"
BUNDLE=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Info.plist")
echo "Bundle: $BUNDLE"

pick_udid() {
  python3 - <<'PY'
import json, subprocess, sys

def simctl(*args):
    return subprocess.check_output(["xcrun", "simctl", *args])

preferred = ["iPhone 16 Pro Max", "iPhone 17 Pro Max", "iPhone 16 Plus"]
data = json.loads(simctl("list", "devices", "available", "-j"))
found = []
for runtime, devices in data.get("devices", {}).items():
    if "iOS" not in runtime:
        continue
    for device in devices:
        if device.get("isAvailable", True):
            found.append((device["name"], device["udid"]))

def choose(pairs):
    for name in preferred:
        for found_name, udid in pairs:
            if found_name == name:
                return udid
    for found_name, udid in pairs:
        if "Pro Max" in found_name:
            return udid
    return None

udid = choose(found)
if udid:
    print(udid)
    sys.exit(0)

types = json.loads(simctl("list", "devicetypes", "-j")).get("devicetypes", [])
runtimes = json.loads(simctl("list", "runtimes", "-j")).get("runtimes", [])
ios = [r for r in runtimes if r.get("isAvailable") and "iOS" in r.get("name", "")]
ios.sort(key=lambda r: r.get("version", ""))
if not ios:
    print("No iOS simulator runtime is installed", file=sys.stderr)
    sys.exit(1)
runtime = ios[-1]["identifier"]
type_id = None
for name in preferred:
    for item in types:
        if item.get("name") == name:
            type_id = item["identifier"]
            break
    if type_id:
        break
if type_id is None:
    for item in types:
        if "Pro Max" in item.get("name", ""):
            type_id = item["identifier"]
            break
if type_id is None:
    print("No Pro Max device type. Available devices:", file=sys.stderr)
    for found_name, found_udid in found:
        print(f"  {found_name} {found_udid}", file=sys.stderr)
    sys.exit(1)
created = subprocess.check_output(
    ["xcrun", "simctl", "create", "Argus Screenshots", type_id, runtime],
    text=True,
).strip()
print(created)
PY
}

UDID=$(pick_udid)
echo "Simulator: $UDID"

xcrun simctl boot "$UDID" || true
xcrun simctl bootstatus "$UDID" -b
xcrun simctl ui "$UDID" appearance dark
xcrun simctl status_bar "$UDID" override \
  --time "9:41" \
  --batteryState charged \
  --batteryLevel 100 \
  --wifiBars 3 \
  --cellularMode active \
  --cellularBars 4

xcrun simctl install "$UDID" "$APP"

# screen key, wait seconds, file stem, headline
shots=(
  "portfolio|5|01-no-account|No account. On your phone."
  "dust|5|02-hide-the-dust|Hide the dust."
  "shown|5|03-one-tap-shows-it-all|One tap shows it all."
  "btc|8|04-know-what-you-paid|Know what you paid."
  "cycle|14|05-see-the-bitcoin-cycle|See the Bitcoin cycle."
  "import|5|06-paste-an-address|Paste an address. Read only."
)

for spec in "${shots[@]}"; do
  IFS='|' read -r screen wait stem headline <<<"$spec"
  echo "Capturing $stem ($screen)"
  xcrun simctl terminate "$UDID" "$BUNDLE" >/dev/null 2>&1 || true
  xcrun simctl launch "$UDID" "$BUNDLE" -ArgusDemoScreenshots -ArgusScreenshot "$screen"
  sleep "$wait"
  xcrun simctl io "$UDID" screenshot "$RAW/$stem.png"
  swift Scripts/compose-app-store-frame.swift "$RAW/$stem.png" "$headline" "$FRAMES/$stem.png"
done

echo "Frames:"
ls -la "$FRAMES"
