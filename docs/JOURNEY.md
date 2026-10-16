# The journey: making a Fitbit Air buzz for coding agents

This is a record of how the project got here: the goal, every approach tried, what turned out to be possible, what did not, and the measurements behind each conclusion. Dates are from October 2026.

## The goal

Feel a buzz on the wrist whenever a coding agent needs a human: when Claude Code or Codex finishes a turn, or when it is waiting for a permission decision or an answer. The agents run on a Mac (terminal and desktop harnesses). The wearable is a Google Fitbit Air, a screenless band, paired to an iPhone.

The requirement that shaped everything: it should be as seamless as possible, with as little manual juggling as possible.

## Dead ends checked first

| Idea | Result |
|---|---|
| Let the Air relay a phone notification | Not possible. The Air does not vibrate for phone notifications; its motor is officially used only for alarms. It is not on Google's list of notification-capable devices. |
| Set an alarm on the Air through an API | Not possible. The Google Health API exposes paired devices read-only and has no alarm, haptics or device-control endpoints. The legacy Fitbit Web API had alarm endpoints, but they never applied to newer devices, and that API is scheduled to stop working on 2026-10-30. |
| Listen for notifications on the iPhone and forward them | Not possible. iOS does not let third-party apps read other apps' notifications. |
| Use the Android bridge as-is | Not applicable. [fitbit-air-notification-bridge](https://github.com/paceaitian/fitbit-air-notification-bridge) is Android only, and the phone here is an iPhone. |

## The key prior art

The Android bridge showed that the Air can be driven directly over Bluetooth Low Energy:

- Transport: BLE GATT, then Fitbit's Golden Gate Gattlink, then IP/UDP, then DTLS with a pre-shared key, then CoAP.
- The DTLS session can use the device's `BOOTSTRAP` identity. That key is hard-coded in Golden Gate's public source, so no secrets or pairing keys are needed.
- Reading the haptics setting: CoAP `PUT /settings` with the protobuf body `0A 01 01`. The response looks like `0A040A0208xx`, where `xx` is 01 Off, 02 Low or 03 High.
- Writing it: `POST /settings` with `0A 04 0A 02 08 xx`. Changing the value makes the Air play a short preview vibration. Writing the same value again does nothing.
- The bridge's buzz: read the original value, write the other one, wait 800 ms, write the original back, read again to verify.
- The Air accepts only one Gattlink/DTLS session at a time.

## Step 1: can the Mac see the Air?

A small CoreBluetooth scanner (`spike/scan.swift`) found nothing Fitbit-like while the iPhone was connected. With the iPhone's Bluetooth off, the Air appeared immediately, advertising the 16-bit service `FD62` (registered to Fitbit). It was on the wrist, not charging; the Air advertises whenever no phone holds it.

## Step 2: what does it expose?

`spike/gatt.swift` connected and listed the GATT services without triggering pairing. The Air calls itself "Google Fitbit Air" and exposes:

- Device Information (`180A`)
- Golden Gate link status (`ABBAFD00`)
- **Gattlink** (`ABBAFF00`), with receive `ABBAFF01` (write without response) and transmit `ABBAFF02` (notify)
- An ephemeral pointer service (`AC2F0045`)
- Heart Rate (`180D`)
- An unknown Google service (`4EEE1C00`) with seven characteristics

Gattlink being there meant the Android trick should work from a Mac.

## Step 3: building Golden Gate on macOS

Golden Gate's iOS/macOS project wants full Xcode and Carthage, so that route was skipped. The portable C library builds fine with CMake (`macOS_cmdline` profile, unit tests off, lwIP and mbedTLS 3 submodules), and its `gg-stack-tool` already includes a CoreBluetooth transport. `scripts/build-golden-gate.sh` reproduces this.

## Step 4: first contact

```
gg-stack-tool --top coap 127.0.0.1 0 5683 --bottom bluetooth <air-id> \
  --dtls-key BOOTSTRAP:<key> hub DSNG
gg-coap-client put -p read.bin coap://127.0.0.1:5683/settings
```

The Air answered `0A040A020802` (Low) on the first try, and the flip-and-restore sequence made it vibrate on the wrist. The Air first offers its own device-specific key identity (starting `MD-`), which fails; the stack then falls back to `BOOTSTRAP`, which succeeds.

## Step 5: the one-connection problem

With the buzz proven, the question became how to share the band with the phone.

| Condition | Air advertisements seen by the Mac |
|---|---|
| iPhone Bluetooth on, Google Health in the background, phone locked (5 min) | 0 |
| iPhone Bluetooth off | Seen immediately; Mac connected |
| iPhone Bluetooth on, Google Health force-quit (5 min) | 468, in bursts; longest quiet gap about 30 s |

Google Health on iOS holds the connection permanently, even in the background, and the Air stops advertising while connected.

Could the Mac connect anyway, without scanning, using the Air's saved macOS ID? No. `spike/direct.swift` tried this twice while the phone held the band (the second time with a freshly scanned ID) and got no connection in 60 seconds. The phone was not disconnected either. The Air accepts exactly one central.

Along the way: **the Air rotates its Bluetooth address**, which changes its macOS peripheral ID. Tools must scan for service `FD62` to find it each time (`spike/find-air.swift`) instead of saving the ID.

## Step 6: options for sharing

1. **iPhone relay app.** A custom iOS app could borrow the phone's existing Bluetooth connection, briefly take over the Gattlink session to buzz, and hand it back. Risks: Google Health's session would likely break and might not recover on its own; waking the app from the Mac needs either Bluetooth between Mac and phone or paid push notifications; it needs full Xcode, and free signing expires every 7 days. Put on hold.
2. **Desk mode handoff from the Mac.** Hand the band to the Mac for the work session and back to the phone afterwards. Tested next.

## Step 7: the desk mode experiment

With Google Health force-quit and the Mac holding a persistent session:

- The Mac found and connected to the Air in about 7 seconds, and the DTLS session came up a second later.
- Buzzes through the held session took 1.0 to 1.2 seconds end to end (0.8 s of that is the deliberate pause between taps). The setting was restored every time.
- Reopening Google Health showed "can't connect". Four buzzes over 3 minutes with Google Health open and the phone locked all worked, with no disconnects or session resets.
- **Handback was automatic.** After the Mac released the band, it advertised for about 2 seconds and then went silent: the iPhone had reconnected by itself. Google Health then synced normally. No force-quit, Bluetooth toggle or re-pairing was needed.
- **Reclaiming without a force-quit did not happen.** With the phone back in control, a Mac waiting to connect saw no advertisements in 10 minutes. That shows it did not happen during the test, not that it is impossible; a natural disconnect such as walking out of range might let the Mac win a race. In practice, each work session starts with one force-quit.

## Step 8: the product

- **Menu bar app** (`app/FitbitBuzz.swift`, built with plain `swiftc`, no Xcode project): Connect to Mac, Release to iPhone, a confirmation buzz on connect, reconnects after drops (with a fresh scan in case the address rotated), and always stops the stack tool on quit or relaunch. An early version of the experiment scripts left the stack tool running after a timeout, still holding the band; the app guards against that.
- **`bin/fitbit-buzz`**: does nothing unless the app reports a connection, serializes concurrent buzzes with a lock, saves the original setting before changing anything, repairs an interrupted run, and verifies the final value.
- **Claude Code hooks**: `Stop` for one pattern, `Notification` (`permission_prompt`, `idle_prompt`, `elicitation_dialog`) for the pattern twice, both async.
- **Codex hooks**: `Stop` for one pattern. Codex has no notification or idle event, so `PermissionRequest` is used for "waiting on you". It cannot be async, so the hook launches the buzz in the background and prints nothing, which leaves the approval decision untouched. New Codex hooks must be trusted in `/hooks` before they run.

Both hook sets were verified working end to end.

## Step 9: strength and count

The setting has only three values (Off, Low, High), so smooth strength control was never possible. The hope was to get gentle-only or strong-only taps.

A first probe (`spike/haptics-probe.sh`) stepped through Low to Off, Off to High, High to Off and Off to Low, four seconds apart, and produced two taps: strong, then gentle. That looked like "switching to Off is silent, switching to High or Low taps", which would allow gentle-only taps (Off then Low, repeated) and strong-only taps (Off then High, repeated).

It was wrong. Gentle taps from a Low band did nothing, even with up to two seconds at Off. Strong with three repeats produced only two taps, strong then gentle. The rule that fits every observation:

- **The band taps only when the intensity becomes a different real value than the last real one.** Becoming High taps strongly and becoming Low taps gently.
- **Off does not count as a value.** Low to Off to Low is "no change" and stays silent.

So every buzz is a flip between Low and High and back, which is always one strong and one gentle tap. The strength slider was removed. A **Vibrations** slider (1 to 5 flip pairs) remains.

The first version of the menu's sliders also stopped responding after several changes. Rebuilding the menu each time it opens, and making the sliders act only on release, fixed that. The menu was later replaced by a SwiftUI popover panel with an iPhone | Mac toggle and tappable vibration bars.

## What is possible, in short

- Buzzing a Fitbit Air from a Mac on demand, with about one second of latency once connected.
- A strong-plus-gentle tap pair, repeated 1 to 5 times.
- Triggering it from Claude Code and Codex hooks.
- Handing the band back to the iPhone automatically.

## What is not possible (or not yet)

- Buzzing while the phone holds the band. The Air takes one connection, and the Mac cannot take it over.
- Getting the band to the Mac without a manual step. Each session starts with force-quitting Google Health.
- Any official route: no phone notification relay, no alarm API, no haptics API.
- Choosing the vibration strength. Only Off, Low and High exist, and only a change between Low and High taps, so every buzz is one strong and one gentle tap.
- An idle buzz in Codex, which has no idle event.

## Open questions

- Is an iPhone relay app viable? It depends mostly on whether Google Health recovers by itself after its Gattlink session is interrupted.
- Does T3 Code fire the permission buzz? It handles approvals in its own interface, so Claude Code's `permission_prompt` notification may not fire there.
- How stable is a held session over several hours, through sleep and wake, or walking out of range?
- Does the unknown Google service `4EEE1C00` offer anything useful?
