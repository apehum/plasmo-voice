#!/usr/bin/env bash
set -uo pipefail

# Usage: answer-prompts.sh <allow|deny> <log> <tcc log stream output> [delay]
#
# The prompt belongs to UserNotificationCenter and exposes no accessibility elements, so System Events
# can't press its buttons. They are hit by position with a real mouse event instead (click.c).

answer=$1
log=$2
tcc_stream=$3
delay=${4:-8}
[[ "$answer" == allow || "$answer" == deny ]] || exit 0

click=$(mktemp -d)/click
clang -O2 -framework ApplicationServices -o "$click" "$(dirname "$0")/click.c" 2>>"$log.err" || exit 1

# "x y w h" of the prompt, empty when none is up. When the window hides its frame as well, falls back to the
# layout seen on a 1024-wide runner screen: 260x233 at y 105, centred
window_frame() {
  osascript -e 'tell application "System Events" to tell (first process whose name is "UserNotificationCenter")
    if (count of windows) is 0 then return ""
    try
      set {x, y} to position of window 1
      set {w, h} to size of window 1
      return (x as text) & " " & (y as text) & " " & (w as text) & " " & (h as text)
    on error
      return "hidden"
    end try
  end tell' 2>/dev/null | {
    read -r frame
    if [[ "$frame" == hidden ]]; then
      width=$(osascript -e 'tell application "Finder" to get item 3 of (bounds of window of desktop)' 2>/dev/null)
      echo "$(( ${width:-1024} / 2 - 130 )) 105 260 233"
    else
      echo "$frame"
    fi
  }
}

prompts_seen() {
  local count
  count=$(grep -c 'AUTHREQ_PROMPTING.*kTCCServiceMicrophone' "$tcc_stream" 2>/dev/null)
  echo "${count:-0}"
}

while true; do
  frame=$(window_frame)
  if [[ -n "$frame" ]] && (( $(prompts_seen) > 0 )); then
    read -r x y w h <<<"$frame"
    # Leaves the prompt up long enough for a screenshot to catch it
    sleep "$delay"
    # Buttons sit side by side 30 pt above the bottom edge: Don't Allow on the left, Allow on the right
    if [[ "$answer" == allow ]]; then bx=$((x + w * 72 / 100)); else bx=$((x + w * 27 / 100)); fi
    by=$((y + h - 30))
    "$click" "$bx" "$by" 2>>"$log.err"
    sleep 3
    result=$(grep -E 'AUTHREQ_RESULT' "$tcc_stream" | grep -E 'authReason=2,' | tail -1 | grep -oE 'authValue=[0-9]+, authReason=[0-9]+')
    still_up=$([[ -n "$(window_frame)" ]] && echo yes || echo no)
    echo "$(date +%H:%M:%S) prompt at $frame: clicked $answer at $bx,$by, still up: $still_up, last answer in TCC: ${result:-none}" >>"$log"
  fi
  sleep 2
done
