# Fitbit agent buzz

Make your Google Fitbit Air vibrate when Claude Code or Codex finishes a task or needs your input, so you can step away from the screen without missing a beat.

- **One pattern** when the agent finishes a turn.
- **The pattern twice** when it is waiting on you (a permission prompt, a question, or idle in Claude Code; an approval request in Codex).

Tested with Claude Code in a terminal and with Codex. Harnesses that load the same hook settings, such as T3 Code, should work too but have not been tested yet.

> Unofficial. Not affiliated with or endorsed by Google, Fitbit, Anthropic or OpenAI. It talks to the band over an undocumented protocol, so a firmware update could break it. Do not rely on it for anything important.

## How it works

The Fitbit Air has no notification support and no public API for vibration. This project uses a trick found by [fitbit-air-notification-bridge](https://github.com/paceaitian/fitbit-air-notification-bridge):

1. Your Mac connects to the Air over Bluetooth using Fitbit's open-source [Golden Gate](https://github.com/Fitbit/golden-gate) stack (Gattlink, then DTLS with the public bootstrap key, then CoAP).
2. When the band's vibration-intensity setting changes between Low and High, it plays a short preview tap: strong when it becomes High, gentle when it becomes Low.
3. A buzz flips the setting to the other level and back (a strong then a gentle tap when your band is on Low), then verifies the original setting is restored.

A menu bar app holds the connection. Agent hooks call `bin/fitbit-buzz`, which sends the setting changes through it.

## The one catch: the Air talks to one device at a time

The Air accepts a single Bluetooth connection, and the Google Health app on your phone keeps it permanently. So the Mac and the phone take turns:

1. Force-quit Google Health on your phone.
2. In the menu bar, choose **Connect to Mac**. You feel one buzz when connected.
3. Reopen Google Health if you like. It shows "can't connect" while the Mac holds the band, which is expected.
4. When you finish working, choose **Release to iPhone**. The phone reconnects by itself within a few seconds and syncs normally. The band keeps recording in the meantime.

If **Connect to Mac** keeps showing "Looking for Fitbit", the phone still holds the band (iOS sometimes relaunches Google Health in the background). Open Google Health, then force-quit it again.

## Requirements

- A Mac with Bluetooth (tested on Apple silicon, macOS 27).
- Xcode Command Line Tools (`xcode-select --install`). Full Xcode is not needed.
- `cmake` and `ninja`: `brew install cmake ninja`.
- A Google Fitbit Air.

## Setup

```sh
git clone https://github.com/HimanshuRattan/fitbit-agent-buzz.git
cd fitbit-agent-buzz
./scripts/build-golden-gate.sh   # builds the Bluetooth stack tools into vendor/bin
./scripts/build-app.sh           # builds build/Fitbit Buzz.app
open "build/Fitbit Buzz.app"     # allow Bluetooth when macOS asks
```

The app records the absolute path of `bin/fitbit-buzz` at build time, so rebuild it if you move the repo.

### Claude Code hooks

Add these to `~/.claude/settings.json`, merging with any hooks you already have. Replace `/path/to/fitbit-agent-buzz` with your clone's path.

```json
{
  "hooks": {
    "Stop": [
      { "hooks": [{ "type": "command", "command": "/path/to/fitbit-agent-buzz/bin/fitbit-buzz single", "async": true }] }
    ],
    "Notification": [
      {
        "matcher": "permission_prompt|idle_prompt|elicitation_dialog",
        "hooks": [{ "type": "command", "command": "/path/to/fitbit-agent-buzz/bin/fitbit-buzz double", "async": true }]
      }
    ]
  }
}
```

### Codex hooks

Add these to `~/.codex/hooks.json`, then run `/hooks` inside Codex and trust them. Codex skips new hooks until you do.

```json
{
  "hooks": {
    "Stop": [
      { "hooks": [{ "type": "command", "command": "/path/to/fitbit-agent-buzz/bin/fitbit-buzz single", "async": true }] }
    ],
    "PermissionRequest": [
      { "hooks": [{ "type": "command", "command": "/path/to/fitbit-agent-buzz/bin/fitbit-buzz double </dev/null >/dev/null 2>&1 &", "timeout": 5 }] }
    ]
  }
}
```

`PermissionRequest` hooks cannot be async in Codex, so the command starts the buzz in the background and prints nothing. That way it never approves or denies anything on your behalf. Codex has no idle event, so there is no buzz for "waiting for your next message".

Hooks are global, so every agent session on the Mac buzzes. When the Mac is not holding the band, `fitbit-buzz` exits immediately and does nothing.

## Buzz settings

The menu has a **Vibrations** slider (1 to 5). Each vibration is a strong tap followed by a gentle one, or the reverse if your band is set to High in Google Health. Releasing the slider plays a preview. The setting is stored in `~/Library/Application Support/notify-fitbit/settings`.

There is no strength control. The band only taps when its intensity changes between Low and High, so every tap pair is one of each. Switching to Off and back to the same value plays nothing.

## Files and logs

| Path | What it is |
|---|---|
| `app/FitbitBuzz.swift` | Menu bar app: finds the band, runs the stack tool, connect and release, vibrations slider |
| `bin/fitbit-buzz` | The command hooks call; locks, buzzes, restores and verifies the setting |
| `scripts/` | Build scripts for the Golden Gate tools, the app and the experiment tools |
| `spike/` | The experiments used to work all this out (see the journey doc) |
| `docs/JOURNEY.md` | What was tried, what worked, what did not, with measurements |

Runtime state and the buzz log live in `~/Library/Application Support/notify-fitbit/`. The stack tool log is `~/Library/Logs/notify-fitbit-stack.log`.

## Credits

- [Golden Gate](https://github.com/Fitbit/golden-gate) by Fitbit, Apache-2.0. Not vendored here; `scripts/build-golden-gate.sh` builds it from source.
- [fitbit-air-notification-bridge](https://github.com/paceaitian/fitbit-air-notification-bridge), Apache-2.0, an Android project that discovered the haptics-setting trick and the bootstrap session. This project ports the idea to macOS and agent hooks.
