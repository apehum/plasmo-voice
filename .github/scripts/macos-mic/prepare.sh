#!/usr/bin/env bash
set -euo pipefail

# Usage: prepare.sh <minecraft version> <usage|no-usage|hardened> <dir with the PV Fabric jar>
#
# Real launchers can't run on a runner (no account, their own dialogs), so a stub app stands in for one.
# TCC only looks at the responsible app's bundle id, Info.plist and signature, which the variant picks:
#   usage     declares NSMicrophoneUsageDescription, like Prism
#   no-usage  doesn't, so TCC can't prompt for it
#   hardened  like the official Minecraft Launcher: hardened runtime, no usage description and no
#             com.apple.security.device.audio-input entitlement

mc=$1
variant=$2
jar_dir=$3
pmc_version=5.0.6
scripts=$(cd "$(dirname "$0")" && pwd)
work="$RUNNER_TEMP/pv-test"
logs="$RUNNER_TEMP/logs"
server="$work/server"
client="$work/client"
app="$work/PV Test Launcher.app"
ua=(-A plasmo-voice-ci)

case "$variant" in
  usage | no-usage | hardened) ;;
  *) echo "::error::Unknown launcher variant $variant"; exit 1 ;;
esac

shopt -s nullglob
jars=("$jar_dir"/*.jar)
if (( ${#jars[@]} != 1 )); then
  echo "::error::Expected one Plasmo Voice jar in $jar_dir, found ${#jars[@]}"
  exit 1
fi

java_major=21
(( ${mc%%.*} >= 26 )) && java_major=25
java_home_var="JAVA_HOME_${java_major}_$([[ $(uname -m) == arm64 ]] && echo ARM64 || echo X64)"
if [[ -z "${!java_home_var:-}" ]]; then
  echo "::error::$java_home_var is not set, setup-java must install Java $java_major"
  exit 1
fi
java="${!java_home_var}/bin/java"

mkdir -p "$work" "$logs" "$server/mods" "$client/mods" "$client/config/plasmovoice"
echo "$java" >"$work/java"

loader=$(curl -fsSL "${ua[@]}" https://meta.fabricmc.net/v2/versions/loader | jq -r '[.[] | select(.stable)][0].version')
installer=$(curl -fsSL "${ua[@]}" https://meta.fabricmc.net/v2/versions/installer | jq -r '[.[] | select(.stable)][0].version')
fabric_api=$(curl -fsSL "${ua[@]}" -G https://api.modrinth.com/v2/project/fabric-api/version \
  --data-urlencode "game_versions=[\"$mc\"]" --data-urlencode 'loaders=["fabric"]' \
  | jq -r 'first(.[]) | (.files | map(select(.primary))[0] // .[0]).url // empty')
if [[ -z "$fabric_api" ]]; then
  echo "::error::No Fabric API build for $mc"
  exit 1
fi
echo "plasmo voice: $(basename "${jars[0]}")"
echo "minecraft $mc, java $java_major, fabric loader $loader, installer $installer"
echo "fabric api: $fabric_api"

curl -fsSL "${ua[@]}" -o "$work/fabric-api.jar" "$fabric_api"
for mods in "$server/mods" "$client/mods"; do
  cp "${jars[0]}" "$mods/plasmovoice.jar"
  cp "$work/fabric-api.jar" "$mods/"
done

curl -fsSL "${ua[@]}" -o "$server/server.jar" \
  "https://meta.fabricmc.net/v2/versions/loader/$mc/$loader/$installer/server/jar"
echo "eula=true" >"$server/eula.txt"
cat >"$server/server.properties" <<'EOF'
online-mode=false
white-list=false
enforce-whitelist=false
level-type=minecraft\:flat
generate-structures=false
spawn-monsters=false
spawn-protection=0
view-distance=4
simulation-distance=4
EOF

# The first-launch accessibility screen sits in front of quick play and never lets the client connect
cat >"$client/options.txt" <<'EOF'
onboardAccessibility:false
skipMultiplayerWarning:true
joinedFirstServer:true
tutorialStep:none
pauseOnLostFocus:false
EOF

# Voice activation at the lowest threshold, so PV sends voice only when the input carries real sound and a
# line that captures silence stays quiet on the wire
cat >"$client/config/plasmovoice/client.toml" <<'EOF'
[voice]
activation_threshold = -60.0

[activations.proximity]
type = "VOICE"
EOF

pmc_arch=$([[ $(uname -m) == arm64 ]] && echo aarch64 || echo x86_64)
pmc="$work/portablemc-$pmc_version-macos-$pmc_arch/portablemc"
if [[ ! -x "$pmc" ]]; then
  curl -fsSL \
    "https://github.com/mindstorm38/portablemc/releases/download/v$pmc_version/portablemc-$pmc_version-macos-$pmc_arch.tar.gz" \
    | tar -xz -C "$work"
fi
pmc_args=(--main-dir "$work/game" start --mc-dir "$client" --jvm "$java" "fabric:$mc:$loader")
# Downloads the game now, so the timed run only covers the launch
"$pmc" "${pmc_args[@]}" --dry

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
clang -O2 -o "$app/Contents/MacOS/launcher" "$scripts/launcher.c"

usage_key=""
if [[ "$variant" == usage ]]; then
  usage_key="<key>NSMicrophoneUsageDescription</key><string>Minecraft mods may use the microphone.</string>"
fi
cat >"$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.plasmovoice.test.launcher.$variant</string>
  <key>CFBundleName</key><string>PV Test Launcher</string>
  <key>CFBundleExecutable</key><string>launcher</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>11.0</string>
  $usage_key
</dict>
</plist>
EOF

{
  echo '#!/bin/bash'
  printf 'exec %q' "$pmc"
  printf ' %q' "${pmc_args[@]}" -u Player --join-server 127.0.0.1 --join-server-port 25565
  printf ' >%q 2>&1\n' "$logs/portablemc.log"
} >"$app/Contents/Resources/launch.sh"

if [[ "$variant" == hardened ]]; then
  codesign --force --options runtime --sign - "$app"
else
  codesign --force --sign - "$app"
fi
codesign -dv "$app" 2>&1 | grep -E 'Identifier|Signature|flags|Info.plist' || true
plutil -p "$app/Contents/Info.plist"
