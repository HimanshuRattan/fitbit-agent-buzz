#!/bin/zsh
# Probe: which haptics-setting transitions make the Air vibrate?
# Steps 4 s apart: original -> OFF, OFF -> HIGH, HIGH -> OFF, OFF -> LOW, then restore original.
# Runs through the connection held by Fitbit Buzz.app, under the same lock as bin/fitbit-buzz.
set -u
STATE_DIR="$HOME/Library/Application Support/notify-fitbit"
[[ "$(cat "$STATE_DIR/state" 2>/dev/null)" == connected ]] || { echo "Mac is not holding the Air"; exit 1; }
if [[ -z "${PROBE_LOCKED:-}" ]]; then
  PROBE_LOCKED=1 exec /usr/bin/lockf -t 30 "$STATE_DIR/buzz.lock" "$0" "$@"
fi

ROOT="${0:A:h:h}"
COAP="$ROOT/build/Fitbit Buzz.app/Contents/Resources/gg-coap-client"
WORK="$(mktemp -d)"
printf '\x0A\x01\x01' > "$WORK/read.bin"
for v in 1 2 3; do printf "\x0A\x04\x0A\x02\x08\x0$v" > "$WORK/$v.bin"; done

coap() {
  rm -f "$WORK/resp.bin"
  "$COAP" "$1" -q -t 3000 -r 1 -p "$2" -s "$WORK/resp.bin" coap://127.0.0.1:5683/settings > /dev/null 2>&1 || return 1
  [[ -f "$WORK/resp.bin" ]] && xxd -p "$WORK/resp.bin" | tr -d '\n' | tr 'a-f' 'A-F'
}
read_intensity() { local r; r="$(coap put "$WORK/read.bin")" || return 1; [[ "$r" == *0A0208* ]] && echo $(( 16#${${r##*0A0208}[1,2]} )); }
name() { case $1 in 1) echo OFF;; 2) echo LOW;; 3) echo HIGH;; *) echo "?$1";; esac; }

original="$(read_intensity)" || { echo "read failed"; exit 1; }
[[ "$original" == 2 || "$original" == 3 ]] || { echo "unexpected intensity $original"; exit 1; }
echo "$original" > "$STATE_DIR/pending-original"
trap 'coap post "$WORK/$original.bin" >/dev/null; rm -f "$STATE_DIR/pending-original"; rm -rf "$WORK"' EXIT

step=1
for next in 1 3 1 2; do
  echo "$(date +%T) step $step: -> $(name $next)"
  coap post "$WORK/$next.bin" > /dev/null || echo "  request failed"
  (( step++ ))
  sleep 4
done
echo "$(date +%T) restoring $(name $original)"
