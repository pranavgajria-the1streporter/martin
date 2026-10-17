# Martin

A stick figure who lives in the menu bar and slides out from under the notch to remind me to sit up, stretch and walk. Version 0.1, built Fri 16 Oct 2026.

## Run it

Martin is in `builds/martin/app/Martin.app`. Double-click it, or:

```bash
open ~/HQ/builds/martin/app/Martin.app
```

His face appears in the menu bar. Click it for today's tally, what's next, do not disturb, pause for an hour, weekends, "Nudge me now" (to try any nudge) and Start at login.

## What he does

- Posture check every 10 minutes of sitting, sit up every 25, stretch every 50 (30 seconds), walk every 90 (one minute). After 22:00 the walk becomes a minute on your feet.
- Five minutes without touching the Mac counts as a break and starts every timer over. So does waking the Mac.
- He stays quiet while the camera is on, while the mic has been on for 2 minutes (a call, not dictation), on weekends (Saturday 06:00 to Monday 06:00, so a late Friday session keeps him) unless turned on, and during do not disturb or a pause.
- A bigger nudge resets the smaller ones under it: a walk resets everything.
- Snooze brings the same nudge back in 10 minutes.

## Change something

- The rhythms: `defaults write co.pranav.martin minutes.walk -int 60` (keys: minutes.posture, minutes.situp, minutes.stretch, minutes.walk), then quit and reopen Martin.
- The look and the lines: `app/Resources/martin.html`. It shares its Martin code with `design/pages/2026-10-16 martin v2.html`.
- After any change: `app/build.sh`, then quit and reopen Martin.

## Files

- `brief.md`: what we decided in the grill.
- `look.md`: the design.
- `app/Sources/Martin/`: the Swift app. `AppDelegate.swift` holds the timers and the menu, `CardWindow.swift` the window under the notch, `Quiet.swift` idle, mic and camera.
- `app/Resources/`: the card page and the ding.

## When he goes quiet

Open `~/Library/Logs/Martin.log` (or click his face: the menu line says why he is holding back). Every launch, nudge, break, wake, camera or mic change and held-back reason is written there, plus an "alive" line every 5 minutes. If he is silent and the log has no recent "alive" line, he has stopped, and that is a bug.

```bash
tail -20 ~/Library/Logs/Martin.log
```

## Testing

`open Martin.app --args --nudge walk` shows a nudge 1.5 seconds after launch. Add `--snapshot /tmp/martin` to save pictures of the card at 3 and 6 seconds.

## Known gaps in 0.1

- Fonts load from Google Fonts. Offline, the card falls back to the system font.
- While a card is up, its clear margin (about 30 points around the card) blocks clicks to whatever is behind it.
- No settings window yet; rhythms change through `defaults write`.
- The camera rule is strict: any app using the camera, Zoom's included, holds every nudge until it stops. When the call ends, the biggest due nudge fires.
