# protoDDT — Features & Shortcuts

protoDDT is an on-screen overlay for Destiny 2 that reads the boss healthbar and
shows live damage numbers. It never touches the game — it only looks at pixels.

All keys below can be changed in `settings.txt`. These are the defaults.
Don't want to learn shortcuts? **F2** opens a quick menu where everything is
a checkbox or a button, each labeled with its key.

## What it does at a glance

- Live boss health %, estimated HP / damage dealt, burst & sustained dps,
  phase duration and time-to-kill on a transparent overlay
- Automatic boss detection: OCR reads the boss's name on screen and locks
  onto it (incl. normal / epic / Pantheon variants), switching bosses
  mid-activity as they appear
- Automatic damage-phase start/stop, hardened against glows, immune dims,
  menus, inventory trips, wipes and 1–2s full-bar melts
- Live graph with three curves (real-time dps, peak dps, total damage),
  movable and resizable in-game
- Phase history: every phase saved to a per-boss session folder with a CSV
  row (incl. best 3s/5s/10s bursts, time-to-first-damage, phases-left
  projection) and an auto-saved graph PNG
- Best-ever phase per boss remembered across sessions ("NEW BEST" notice)
- One-key Discord-pasteable phase summary
- Measurement tools for unknown bosses: per-hit CSV logger with hit stats,
  known-weapon HP measuring, and a %-only "default" mode
- Tracker state dot (idle / locked / phase) + self-resetting watchdog
- Overlay drawn over the game, or everything in a separate window instead
- Works at 1080p / 1440p out of the box, any resolution via the calibration
  wizard, colorblind modes and brightness levels supported

## Quick reference

| Key | What it does |
|-----|--------------|
| **F2** | Quick menu: every toggle and action as buttons, no shortcuts needed |
| **F3** | Start/stop a damage phase by hand (only when manual mode is on) |
| **F4** | Close protoDDT |
| **F5** | Reload protoDDT (after editing settings.txt or the boss file) |
| **F6** | Boss window: pick a boss manually, measure a boss, calibrate |
| **F7** | Detect the boss on screen now (reads its name above the bar) |
| **F8** | Cycle which graph curves are shown: all → dps → peak → damage |
| **F9** | Graph edit mode: drag to move, mouse-wheel to resize, F9 again saves |
| **F10** | Switch encounter context: normal → epic → pantheon |
| **F11** | Start/stop the measurement CSV logger (one row per hit) |
| **F12** | Copy the last phase summary to the clipboard (paste in Discord) |
| **Ctrl+Esc** | Emergency exit |

## The overlay

- **Boss health** — big percentage plus the estimated HP (or damage dealt,
  switchable in settings), calculated from the healthbar and the boss's known
  max HP from `Boss_full_name+HP.txt`.
- **Burst / Sustained** — highest and average damage-per-second of the phase.
- **DPS Phase / Time To Kill** — how long the current phase has run, and how
  long the boss would live at the current dps.
- **State dot** (next to the health numbers) —
  ⚫ gray: idle, nothing tracked · 🔵 blue: boss found and locked ·
  🟠 orange: damage phase running.
- The overlay only shows while Destiny 2 is the active window.
- Prefer a movable window instead of an overlay? Set
  `Display info in a separate window = true`.

## Automatic boss detection (OCR)

- Every few seconds, if a healthbar is visible, the boss's name under the bar
  is read with OCR (several image-processing passes, so it works over messy
  backgrounds), matched against `Boss_full_name+HP.txt`, and the tracker
  locks onto that boss automatically — including switching to a new boss
  mid-activity when a different name appears. **F7** forces a detection now.
- Same-named bosses (normal / epic / Pantheon versions) are told apart by the
  **Encounter Context** setting — cycle it with **F10**.
- If the bar disappears (activity over) or something bar-like has no boss name
  above it (like the XP bar), the tracker resets itself back to idle after a
  few seconds — no manual cleanup needed.

## Damage phases (automatic)

- A phase **starts** when the bar visibly drops and keeps dropping — even slow
  trickle damage is picked up. It **ends** when the bar hasn't moved for
  10 seconds (`Phase End After Frozen Seconds`), when the boss dies (the
  final sliver of damage is counted, even on 1–2s full-bar melts), or when
  the bar refills (wipe).
- Opening your inventory mid-phase is fine: the timer keeps running and the
  reading catches up instantly with your teammates' damage when you close it.
- The tracker is heavily armored against fake readings: glowing bar sections,
  immune-phase dims, menus, the character screen, one-frame flickers and
  1–2-second full-bar melts are all handled. If a phase turns out to be a
  visual artifact, it's thrown away as if it never happened.
- Prefer full control? Set `Manually Start and Stop DPS Phases = true` and use
  **F3** to start/stop phases yourself.

## The graph

- Appears automatically during a phase, lingers a few seconds after it ends.
- Three curves: **orange** = real-time dps (1-second window), **red** = peak
  dps so far, **blue** = total damage. **F8** cycles which ones are drawn.
- **F9** toggles edit mode: drag the graph anywhere, resize with the mouse
  wheel, press **F9** again to save the layout permanently.

## Phase history & sharing

Everything a session produces lands in one folder per boss and day:
`Tracking\<Boss>_<Normal|Epic|Pantheon>_<date>\` — e.g.
`Tracking\Dredgen Sere_Normal_2026-07-19\`.

- **phases.csv** (in that folder) — one line per real phase: attempt number,
  duration, damage, average dps, peak dps, best 3s / 5s / 10s burst dps,
  time-to-first-damage, hp range, kill flag, and a "phases left to kill it at
  this rate" projection.
- **Graph PNG** — the final dps/damage curve of every phase is saved
  automatically as `phase_<attempt>_<time>.png`.
- **Best records** — `Tracking\best_records.csv` keeps your best-ever phase
  per boss; beating it pops a "NEW BEST PHASE" notice on screen.
- **F12** copies the last phase as one line of text, e.g.
  `Dredgen Sere #3 - 23.8s, 1,421,924 dmg, 59,745 avg dps, 92,300 peak dps
  (94.8% -> 5.2%) | best 5s: 110,200 dps | ~2.3 phases left`.

## Measuring unknown bosses

- **F11 CSV logger** — while on, writes one clean row per hit you land
  (time, hp%, damage) to a `dpslog_*.csv` (saved into the boss's Tracking
  folder when one is locked). Stopping it shows and appends session stats:
  hit count, average hit, and hits per minute. Press **F11** again to stop.
- **Measure mode (in F6)** — enter the damage of one hit of a known weapon,
  press Measure, land a few spaced shots: it estimates the boss's max HP and
  can save it straight into `Boss_full_name+HP.txt`.
- **"default" boss (in F6)** — pick this to track any boss without knowing its
  HP: damage shows as % of the bar instead of hit points.

## The boss data file

`Boss_full_name+HP.txt` is the single source of truth. One line per boss:

```
"Exact On-Screen Name" = 14795550 ,0
```

- The number after the comma is the count of final-stand health breaks
  (`,1` = has a final stand).
- Plain lines act as section headers; a header containing `(Epic)` or
  `PANTHEON` marks every boss below it as that variant.
- Tag a boss `(No Boss HP bar)` to keep it out of OCR detection.
- Edit the file, press **F5**, done — the F6 dropdown and detection pick it
  up. Measure mode can also append entries for you.

## Screen setup

- Presets for 1920×1080 and 1440p (plus ultrawide) are built in — pick in
  `settings.txt`.
- Any other resolution: use **Calibrate bar location** in the F6 window (or
  set a `Calibrate Hotkey`): hover the LEFT end of the boss bar, press Space,
  hover the RIGHT end, press Space. Saved permanently, applied immediately.
- Colorblind modes (Normal / Deuteranopia / Protanopia / Tritanopia) and
  in-game brightness levels 2–7 are supported — set both in `settings.txt` to
  match your game settings.

## Files

| File | Purpose |
|------|---------|
| `settings.txt` | All settings and hotkeys (edit, then **F5** to reload) |
| `Boss_full_name+HP.txt` | Boss names + max HP (the single source of truth) |
| `Tracking\<Boss>_<Type>_<date>\` | Per-session folder: phase history, graph PNGs, F11 logs |
| `Tracking\best_records.csv` | Best-ever phase per boss, across all sessions |
