#!/usr/bin/env bash
set -uo pipefail

work="$RUNNER_TEMP/pv-test"
logs="$RUNNER_TEMP/logs"
mkdir -p "$logs"

for side in client server; do
  [[ -d "$work/$side/logs" ]] && mkdir -p "$logs/$side" && cp "$work/$side/logs"/*.log "$logs/$side"/ 2>/dev/null
done

# Native crashes too: TCC kills the game outright when it asks for the microphone without a usage description
for dir in ~/Library/Logs/DiagnosticReports /Library/Logs/DiagnosticReports; do
  find "$dir" -maxdepth 1 \( -name 'java*' -o -name 'PV*' -o -name 'launcher*' \) -newermt '-3 hours' 2>/dev/null
done | while read -r report; do mkdir -p "$logs/crashes" && cp "$report" "$logs/crashes/"; done
shopt -s nullglob
for report in "$work"/client/hs_err_pid*.log; do mkdir -p "$logs/crashes" && cp "$report" "$logs/crashes/"; done

log show --last 3h --style compact --predicate 'subsystem == "com.apple.TCC"' >"$logs/tcc-unified.log" 2>&1 || true
