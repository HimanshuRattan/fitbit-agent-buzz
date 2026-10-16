#!/bin/zsh
# Spike: talk to the Fitbit Air from this Mac through Golden Gate's stack tool.
#
#   ./air.sh read        one-shot: connect, read the haptics intensity (no vibration), disconnect
#   ./air.sh buzz        one-shot: connect, flip the intensity and flip it back (buzz), disconnect
#   ./air.sh hold        run the stack in the foreground and keep the Air connected (Ctrl-C releases)
#   ./air.sh read-held   read through a stack started with `hold`
#   ./air.sh buzz-held   buzz through a stack started with `hold`
#
# The Air's current ID is found by scanning (override with AIR_ID=...).
# Requires the iPhone to not be holding the Air (e.g. Google Health force-quit).
# The DTLS key is the public BOOTSTRAP key from Fitbit's open-source Golden Gate repo.
set -u
cd "${0:A:h}"

BOOTSTRAP_KEY="BOOTSTRAP:810654E336ADCAB0A03C60F74AA0B6FB"
MODE="${1:-read}"
WORK="$(mktemp -d)"
LOG="$WORK/stack.log"
# Last known-good intensity, so an interrupted buzz can be recovered by hand
ORIGINAL_FILE="$PWD/.haptics-original"

# Protobuf payloads from the Android bridge's AirDirectSettingsProtocol.kt
printf '\x0A\x01\x01' > "$WORK/read.bin"                 # SettingsRequest { HAPTICS }
printf '\x0A\x04\x0A\x02\x08\x02' > "$WORK/low.bin"      # haptics_intensity = LOW
printf '\x0A\x04\x0A\x02\x08\x03' > "$WORK/high.bin"     # haptics_intensity = HIGH

ts() { date +%H:%M:%S; }

find_air() { # the macOS ID changes whenever the Air rotates its Bluetooth address
  AIR_ID="${AIR_ID:-$(./find-air 60)}" || { echo "$(ts) Air not advertising (is the iPhone holding it?)"; exit 1; }
}

start_stack() {
  GG_LOG_CONFIG="${GG_LOG_CONFIG:-plist:.level=INFO}" ../vendor/bin/gg-stack-tool --top coap 127.0.0.1 0 5683 --bottom bluetooth "$AIR_ID" \
    --dtls-key "$BOOTSTRAP_KEY" hub DSNG "$@"
}

coap() { # method payload-file -> prints response hex, fails on error
  local out="$WORK/resp.bin"
  rm -f "$out"
  ../vendor/bin/gg-coap-client "$1" -q -t 4000 -r 1 -p "$2" -s "$out" coap://127.0.0.1:5683/settings >> "$WORK/coap.log" 2>&1 || return 1
  [[ -f "$out" ]] && xxd -p "$out" | tr -d '\n' | tr 'a-f' 'A-F'
}

intensity() { # response hex -> 2 (LOW) or 3 (HIGH); matches the 0A040A0208xx shape
  [[ "$1" == *0A0208* ]] && echo $(( 16#${${1##*0A0208}[1,2]} ))
}

read_intensity() { # tries up to $1 times, prints the intensity
  local resp
  for i in {1..$1}; do
    resp="$(coap put "$WORK/read.bin")" && [[ -n "$resp" ]] && { intensity "$resp"; return 0; }
    (( i < $1 )) && sleep 2
  done
  return 1
}

buzz() {
  local t0=$EPOCHREALTIME original flip restore final
  original="$(read_intensity 1)" || { echo "$(ts) read failed"; return 1; }
  if [[ "$original" != 2 && "$original" != 3 ]]; then
    echo "$(ts) unexpected intensity '$original', not touching settings"; return 1
  fi
  echo "$original" > "$ORIGINAL_FILE"
  if [[ "$original" == 3 ]]; then flip="$WORK/low.bin"; restore="$WORK/high.bin"; else flip="$WORK/high.bin"; restore="$WORK/low.bin"; fi
  coap post "$flip" > /dev/null || echo "$(ts) flip request failed"
  sleep 0.8
  coap post "$restore" > /dev/null || echo "$(ts) restore request failed"
  final="$(read_intensity 2)"
  printf '%s buzz took %.1fs, intensity %s -> %s\n' "$(ts)" $(( EPOCHREALTIME - t0 )) "$original" "${final:-unknown}"
  if [[ "$final" != "$original" ]]; then
    echo "WARNING: intensity not restored (expected $original). Fix it in the Google Health app if needed."
    return 1
  fi
}

zmodload zsh/datetime

case "$MODE" in
  hold)
    find_air
    echo "$(ts) holding $AIR_ID (Ctrl-C to release)"
    start_stack 2>&1 | while IFS= read -r line; do echo "$(ts) $line"; done
    echo "$(ts) stack exited, Air released"
    exit 0 ;;
  read-held)
    v="$(read_intensity 1)" && echo "$(ts) intensity=$v (2=LOW 3=HIGH)" || { echo "$(ts) no response through held stack"; tail -5 "$WORK/coap.log"; exit 1; }
    exit 0 ;;
  buzz-held)
    buzz; exit $? ;;
  read|buzz)
    find_air
    start_stack > "$LOG" 2>&1 &
    STACK_PID=$!
    trap 'kill $STACK_PID 2>/dev/null; wait $STACK_PID 2>/dev/null' EXIT
    echo "Connecting to $AIR_ID (up to 30s)..."
    if ! v="$(read_intensity 10)"; then
      echo "No response from the Air. Stack tool log:"; tail -40 "$LOG"
      echo "--- CoAP client log:"; tail -20 "$WORK/coap.log"
      exit 1
    fi
    echo "Haptics intensity=$v (2=LOW 3=HIGH)"
    [[ "$MODE" == read ]] && exit 0
    buzz; exit $? ;;
  *)
    echo "usage: $0 read|buzz|hold|read-held|buzz-held"; exit 2 ;;
esac
