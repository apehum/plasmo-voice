#!/usr/bin/env bash
set -uo pipefail

# Runs one case from the macos-mic.yml matrix against the game prepare.sh set up, and fails when PV didn't
# do what the case expects. The case comes from the environment: CASE_NAME, CASE_LAUNCHER_MIC
# (fresh|allowed|denied), CASE_HELPER_MIC (fresh|allowed), CASE_ANSWER (none|allow|deny), CASE_EXPECT
# (javax|coreaudio|denied), CASE_HELPER (true|false).

name=${CASE_NAME:?}
launcher_mic=${CASE_LAUNCHER_MIC:-fresh}
helper_mic=${CASE_HELPER_MIC:-fresh}
answer=${CASE_ANSWER:-none}
expect=${CASE_EXPECT:?}
expect_helper=${CASE_HELPER:?}
minutes=${CASE_MINUTES:-10}
scripts=$(cd "$(dirname "$0")" && pwd)
work="$RUNNER_TEMP/pv-test"
logs="$RUNNER_TEMP/logs"
server="$work/server"
server_log="$server/logs/latest.log"
client_log="$work/client/logs/latest.log"
app="$work/PV Test Launcher.app"
java=$(cat "$work/java")
launcher_id=$(defaults read "$app/Contents/Info.plist" CFBundleIdentifier)
helper_id=com.plasmovoice.mic
user_db="$HOME/Library/Application Support/com.apple.TCC/TCC.db"
mkdir -p "$logs/screens"

case "$expect" in
  javax | coreaudio) expected_device=$expect expected_voice=true ;;
  denied) expected_device=none expected_voice=false ;;
  *) echo "::error::Unknown expectation $expect"; exit 1 ;;
esac

seen() { grep -qE "$1" "$2" 2>/dev/null; }

# auth_value 0 is denied, 2 allowed
set_mic() {
  sqlite3 "$user_db" "insert or replace into access
    (service, client, client_type, auth_value, auth_reason, auth_version, indirect_object_identifier, flags)
    values ('kTCCServiceMicrophone', '$1', 0, $2, 4, 1, 'UNUSED', 0)" \
    || { echo "::error::Can't write $user_db"; exit 1; }
}

tcc_dump() {
  local query="select client, client_type, auth_value, auth_reason, datetime(last_modified, 'unixepoch') as modified
    from access where service = 'kTCCServiceMicrophone' order by client"
  echo "=== user"
  sqlite3 -header -column "$user_db" "$query" 2>&1
  echo "=== system"
  sudo -n sqlite3 -header -column "/Library/Application Support/com.apple.TCC/TCC.db" "$query" 2>&1
}

details() {
  printf '<details><summary>%s</summary>\n\n```\n%s\n```\n</details>\n\n' "$1" "$2"
}

for id in "$launcher_id" "$helper_id"; do tccutil reset Microphone "$id" >/dev/null 2>&1 || true; done
case "$launcher_mic" in
  fresh) ;;
  allowed) set_mic "$launcher_id" 2 ;;
  denied) set_mic "$launcher_id" 0 ;;
  *) echo "::error::Unknown launcher permission $launcher_mic"; exit 1 ;;
esac
case "$helper_mic" in
  fresh) ;;
  allowed) set_mic "$helper_id" 2 ;;
  *) echo "::error::Unknown helper permission $helper_mic"; exit 1 ;;
esac
killall tccd 2>/dev/null || true
tcc_dump >"$logs/tcc-before.txt"

pushd "$server" >/dev/null
nohup "$java" -Xmx2G -jar server.jar nogui </dev/null >"$logs/server-console.log" 2>&1 &
server_pid=$!
popd >/dev/null
for _ in $(seq 300); do
  seen 'Done \(' "$server_log" && break
  if ! kill -0 "$server_pid" 2>/dev/null; then
    tail -40 "$logs/server-console.log"
    echo "::error::The server exited during startup"
    exit 1
  fi
  sleep 1
done
if ! seen 'Done \(' "$server_log"; then
  echo "::error::The server didn't start in 5 minutes"
  exit 1
fi

# BlackHole loops its output back into its input, so the tone is what every backend reads as the microphone
SwitchAudioSource -t input -s "BlackHole 2ch" >"$logs/audio-setup.log" 2>&1
nohup sox -q -n -t coreaudio "BlackHole 2ch" synth 3600 sine 440 vol 0.5 </dev/null >"$logs/tone.log" 2>&1 &
tone=$!
# PV's UDP shares the server port: voice is ~50 packets/s, keepalives ~1/s
sudo -n tcpdump -i lo0 -n -l -tt 'udp and dst port 25565' </dev/null >"$logs/udp.log" 2>"$logs/tcpdump.err" &

nohup log stream --style compact --info --predicate 'subsystem == "com.apple.TCC"' </dev/null >"$logs/tcc-stream.log" 2>&1 &
stream=$!
"$scripts/answer-prompts.sh" "$answer" "$logs/prompt-answers.log" "$logs/tcc-stream.log" </dev/null >/dev/null 2>&1 &
answerer=$!

# Through open, so launchd spawns the stand-in and it is the game's responsible process, as a launcher is when a
# player starts it. Spawned from this shell, the runner's agent would be responsible for the game instead
open -n -a "$app" </dev/null >/dev/null 2>&1

opened_re='(JavaxInputDevice|CoreAudioInputDevice)\] Device .* initialized'
helper_re='macOS microphone helper started'
failed_re='Failed to open input device|No input backend could open'
helper_seen=false
opened=false
helper_logged=false
failed=false
joined_at=""
stop_at=""
reason="time limit ($minutes min)"
deadline=$((SECONDS + minutes * 60))
tick=0
while (( SECONDS < deadline )); do
  pgrep -qf PVMicHelper && helper_seen=true
  if [[ -z "$joined_at" ]] && seen 'joined the game' "$server_log"; then joined_at=$SECONDS; fi

  if ! $opened && seen "$opened_re" "$client_log"; then
    # Long enough to count voice packets
    opened=true stop_at=$((SECONDS + 25)) reason="input device opened"
  elif ! $opened && ! $helper_logged && seen "$helper_re" "$client_log"; then
    # Time for the helper's prompt to be answered and its device to open
    helper_logged=true stop_at=$((SECONDS + 45)) reason="helper started"
  elif ! $opened && ! $failed && seen "$failed_re" "$client_log"; then
    # A failed first open can still be followed by a working reopen
    failed=true reason="input device failed"
    (( ${stop_at:-0} < SECONDS + 30 )) && stop_at=$((SECONDS + 30))
  fi

  if seen 'Minecraft has crashed|---- Minecraft Crash Report|Stopping!' "$client_log"; then
    reason="client stopped"
    break
  fi
  if [[ -f "$client_log" ]] && ! pgrep -qf KnotClient; then
    reason="client exited"
    break
  fi
  if [[ -z "$stop_at" ]] && seen 'lost connection' "$server_log"; then
    reason="client disconnected: $(grep -m1 -o 'lost connection: .*' "$server_log")"
    stop_at=$((SECONDS + 5))
  fi
  if [[ -z "$stop_at" && -n "$joined_at" ]] && (( SECONDS - joined_at > 60 )); then
    reason="no input device news 60 s after joining"
    break
  fi
  [[ -n "$stop_at" ]] && (( SECONDS >= stop_at )) && break

  (( tick++ % 3 == 0 )) && screencapture -x "$logs/screens/$(date +%H%M%S).png" 2>/dev/null
  sleep 5
done
screencapture -x "$logs/screens/$(date +%H%M%S)-final.png" 2>/dev/null

# Independent of PV: whether the tone was still reaching BlackHole's input at the end
tone_rms=$(sox -q -t coreaudio "BlackHole 2ch" -n trim 0 2 stat 2>&1 | tee "$logs/blackhole-level.txt" \
  | awk '/RMS +amplitude/ { print $3 }')
# What each client thread was blocked on, for runs that stall behind a prompt
for pid in $(pgrep -f KnotClient); do
  "$(dirname "$java")/jcmd" "$pid" Thread.print >"$logs/client-threads-$pid.txt" 2>&1 || true
done
tcc_dump >"$logs/tcc-after.txt"

kill "$stream" "$answerer" "$tone" 2>/dev/null
sudo -n pkill tcpdump 2>/dev/null
pkill -f "$work" 2>/dev/null
kill "$server_pid" 2>/dev/null
pkill -f PVMicHelper 2>/dev/null

peak=$(awk '{ c[int($1 / 10)]++ } END { m = 0; for (k in c) if (c[k] > m) m = c[k]; print m }' "$logs/udp.log" 2>/dev/null)
peak=${peak:-0}

backend=none
seen 'JavaxInputDevice\] Device .* initialized' "$client_log" && backend=javax
seen 'CoreAudioInputDevice\] Device .* initialized' "$client_log" && backend=coreaudio
seen "$helper_re" "$client_log" && helper_seen=true
denied=false
seen 'Microphone access is DENIED' "$client_log" && denied=true
voice=false
(( peak >= 100 )) && voice=true
joined=false
[[ -n "$joined_at" ]] && joined=true

rows=()
failures=0
check() {
  local result=pass
  if [[ "$2" != "$3" ]]; then
    result="**fail**"
    failures=$((failures + 1))
  fi
  rows+=("| $1 | $2 | $3 | $result |")
}
check "client joined the server" true "$joined"
check "input device" "$expected_device" "$backend"
check "helper ran" "$expect_helper" "$helper_seen"
check "voice reached the server" "$expected_voice" "$voice"
[[ "$expect" == denied ]] && check "permission denied in the log" true "$denied"

pv_lines=$(grep -nE 'LauncherMicrophone|HelperSupervisor|CoreAudioInputDevice|JavaxInputDevice|VoiceDeviceManager|macOS microphone|Microphone access|input device|falling back' \
  "$client_log" 2>/dev/null || echo "no PV device lines")
{
  echo "### $name: $( (( failures == 0 )) && echo passed || echo '**failed**' )"
  echo
  echo "Launcher \`$launcher_id\` $launcher_mic, helper $helper_mic, prompts answered: $answer. Stopped on: $reason."
  echo
  echo "| check | expected | actual | |"
  echo "|---|---|---|---|"
  printf '%s\n' "${rows[@]}"
  echo
  echo "- Busiest 10 s: $peak client-to-server packets (voice is ~500, keepalives ~10)"
  echo "- Tone at BlackHole's input at the end: RMS ${tone_rms:-unknown} (a 0.5 sine is ~0.35)"
  echo "- Launcher signature: $(codesign -dv "$app" 2>&1 | grep -E '^(Signature|CodeDirectory)' | tr '\n' ';' | sed 's/;$//')"
  clicks=$(tr '\n' ';' 2>/dev/null <"$logs/prompt-answers.log" | sed 's/;$//')
  echo "- Prompts clicked: ${clicks:-none}"
  echo
  details "PV device log" "$pv_lines"
  details "TCC microphone requests" "$(grep -i microphone "$logs/tcc-stream.log" 2>/dev/null | tail -40)"
} | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"

(( failures == 0 ))
