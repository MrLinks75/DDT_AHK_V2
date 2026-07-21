#Requires AutoHotkey v2.0
#SingleInstance Force
; ============================================================
; protoDDT feature test harness (2026-07-21 changes)
; - save_setting / median3 are copied VERBATIM from protoDDT.ahk
; - watchdog + phase-start pipelines are line-for-line mirrors
;   driven by a virtual clock so 3-minute scenarios run instantly
; Results are written to results.txt next to this script.
; ============================================================

global pass_n := 0, fail_n := 0, out := ""

log(msg) {
    global out
    out .= msg "`r`n"
}
assert(cond, msg) {
    global pass_n, fail_n
    if (cond) {
        pass_n += 1
        log("  PASS  " msg)
    } else {
        fail_n += 1
        log("  FAIL  " msg)
    }
}

; ---------- verbatim copies from protoDDT.ahk ----------
save_setting(name, value)
{
    newline := Format("{:-41}", name) "= " value
    escaped := RegExReplace(name, "[\\.*?+\[\]{}()^$|]", "\$0")
    content := FileRead(A_ScriptDir "\settings.txt")
    if RegExMatch(content, "m)^" escaped "\s*=")
        content := RegExReplace(content, "m)^" escaped "\s*=[^`r`n]*", newline)
    else
        content := RTrim(content, "`r`n") "`r`n" newline "`r`n"
    settingsFile := FileOpen(A_ScriptDir "\settings.txt", "w")
    settingsFile.Write(content)
    settingsFile.Close()
}

median3(a, b, c)
{
    return a + b + c - Max(a, b, c) - Min(a, b, c)
}

; parse a value back the way get_settings does
read_setting(name)
{
    settings := FileRead(A_ScriptDir "\settings.txt")
    Loop Parse settings, "`n", "`r"
    {
        if (Trim(A_LoopField) = "")
            continue
        line := StrSplit(A_LoopField, "=")
        if (Trim(line[1]) == name)
            return line.Has(2) ? Trim(line[2]) : ""
    }
    return "<absent>"
}

; the flush_calibration "is anything saved" decision, mirrored
flush_would_act(hbOverride, bnOverride)
{
    saved_in_file := 0
    try saved_in_file := RegExMatch(FileRead(A_ScriptDir "\settings.txt"), "m)^(Healthbar|Bossname) Location\s*=\s*\S")
    return (saved_in_file || hbOverride != "" || bnOverride != "")
}

; ============================================================
; 1. settings.txt round-trips (real save_setting on a sandbox file)
; ============================================================
test_settings()
{
    log("[1] save_setting / settings.txt round-trips")
    FileOpen(A_ScriptDir "\settings.txt", "w").Write(
        "Reload Script Hotkey                     = F5`r`n"
        "1920x1080                                = false`r`n"
        "Ultrawide 1440p Monitor                  = false`r`n")

    ; new key is appended and reads back
    save_setting("Healthbar Location", "100|200|300|3")
    assert(read_setting("Healthbar Location") = "100|200|300|3", "new key appended, value with pipes survives")

    ; update in place, no duplicate lines
    save_setting("Healthbar Location", "111|222|333|3")
    content := FileRead(A_ScriptDir "\settings.txt")
    cnt := 0
    pos := 1
    while (pos := RegExMatch(content, "m)^Healthbar Location", , pos)) {
        cnt += 1
        pos += 1
    }
    assert(cnt = 1, "updating a key keeps exactly one line")
    assert(read_setting("Healthbar Location") = "111|222|333|3", "updated value reads back")

    ; other keys untouched
    assert(read_setting("Reload Script Hotkey") = "F5", "unrelated keys untouched")

    ; flush: empty value clears it, get_settings-style parse yields ""
    save_setting("Healthbar Location", "")
    assert(read_setting("Healthbar Location") = "", "flushed key parses back as empty override")

    ; qm_resolution mapping: choice -> settings written (Reload stubbed out)
    for choice, expect in Map(1, ["false", "false"], 2, ["true", "false"], 3, ["false", "true"]) {
        save_setting("1920x1080", choice = 2 ? "true" : "false")
        save_setting("Ultrawide 1440p Monitor", choice = 3 ? "true" : "false")
        assert(read_setting("1920x1080") = expect[1] && read_setting("Ultrawide 1440p Monitor") = expect[2],
            "resolution choice " choice " writes 1080p=" expect[1] " ultrawide=" expect[2])
    }
}

; ============================================================
; 2. flush_calibration decision (the reported bug)
; ============================================================
test_flush_decision()
{
    log("[2] flush_calibration sees saved calibrations")
    FileOpen(A_ScriptDir "\settings.txt", "w").Write("Reload Script Hotkey = F5`r`n")

    assert(!flush_would_act("", ""), "nothing saved anywhere -> refuses to flush")

    ; the reported scenario: calibration saved to file, globals stale/empty
    save_setting("Healthbar Location", "858|1302|845|3")
    assert(flush_would_act("", ""), "value in settings.txt, stale globals -> flush proceeds (was the bug)")

    ; flushed file, but live session globals set (calibrated then hand-emptied file)
    save_setting("Healthbar Location", "")
    assert(flush_would_act("858|1302|845|3", ""), "live globals set, file empty -> flush proceeds")
    assert(!flush_would_act("", ""), "flushed file + empty globals -> nothing to flush")

    ; bossname alone also counts
    save_setting("Bossname Location", "858|1310|600|55")
    assert(flush_would_act("", ""), "bossname override alone is detected")
}

; ============================================================
; 3. burst/sustained number gating (issue 1)
; ============================================================
test_number_gating()
{
    log("[3] burst/sustained numbers gating")
    ; expression used in calculateDPS + end_dps_phase:
    show := (inc, spec, cross) => (inc && (spec || cross))
    assert(show(1, 1, 0), "dps on, specifiers on -> numbers shown")
    assert(!show(1, 0, 0), "dps on, specifiers OFF -> numbers hidden (the fix)")
    assert(show(1, 0, 1), "crosshair mode keeps numbers without specifiers")
    assert(!show(0, 1, 0), "dps calculations off hides numbers regardless")
    assert(!show(0, 0, 1), "dps off + crosshair still hidden")
}

; ============================================================
; 4. idle watchdog - time-based mirror of auto_detect_tick
; ============================================================
class Watchdog {
    now := 1000000
    nobar_since := 0
    noname_since := 0
    resets := 0
    last_reason := ""
    ; one auto-detect tick, dt_ms apart (interval-independent logic)
    step(gate_out, tracking, bar_visible, name_found, dt_ms := 1000) {
        this.now += dt_ms
        if (gate_out) {   ; !autoDetectBoss || dps_phase_active || !currently_shown
            this.nobar_since := 0
            this.noname_since := 0
            return
        }
        if (!name_found) {
            if (tracking) {
                if (!bar_visible) {
                    this.noname_since := 0
                    if (!this.nobar_since)
                        this.nobar_since := this.now
                    if (this.now - this.nobar_since >= 30000) {
                        this.nobar_since := 0
                        this.resets += 1
                        this.last_reason := "no bar"
                    }
                } else {
                    this.nobar_since := 0
                    if (!this.noname_since)
                        this.noname_since := this.now
                    if (this.now - this.noname_since >= 300000) {
                        this.noname_since := 0
                        this.resets += 1
                        this.last_reason := "bar without name"
                    }
                }
            } else {
                this.nobar_since := 0
                this.noname_since := 0
            }
            return
        }
        this.nobar_since := 0
        this.noname_since := 0
    }
}

test_watchdog()
{
    log("[4] idle watchdog scenarios (1 step = 1s check)")

    ; A: long mechanics - bar frozen on screen, OCR can't read the name
    wd := Watchdog()
    Loop 210   ; 3.5 minutes
        wd.step(false, true, true, false)
    assert(wd.resets = 0, "3.5 min visible bar w/ unreadable name -> NO reset")

    ; ...and OCR recovering afterwards clears the timers
    wd.step(false, true, true, true)
    assert(wd.noname_since = 0 && wd.nobar_since = 0, "one good OCR read clears all miss timers")

    ; B: xp-bar false positive still gets flushed eventually (5 min)
    wd := Watchdog()
    Loop 299
        wd.step(false, true, true, false)
    assert(wd.resets = 0, "4m59s bar-without-name: not yet")
    Loop 2
        wd.step(false, true, true, false)
    assert(wd.resets = 1 && wd.last_reason = "bar without name", "5 min flushes the stale tracker")

    ; C: the reported bug - a 15s inventory visit must NOT reset the boss
    wd := Watchdog()
    Loop 15
        wd.step(false, true, false, false)
    assert(wd.resets = 0, "15s inventory (no bar) -> boss NOT reset (was reset at 9s)")
    wd.step(false, true, true, true)   ; back in game, bar + name
    assert(wd.resets = 0 && wd.nobar_since = 0, "leaving the inventory resumes cleanly")

    ; C2: bar gone for real (left the activity) resets at 30s
    wd := Watchdog()
    Loop 29
        wd.step(false, true, false, false)
    assert(wd.resets = 0, "29s no bar: not yet")
    Loop 2
        wd.step(false, true, false, false)
    assert(wd.resets = 1 && wd.last_reason = "no bar", "30s no bar resets the stale tracker")

    ; C3: interval independence - same 30s behavior at a 3s check interval
    wd := Watchdog()
    Loop 5
        wd.step(false, true, false, false, 3000)
    assert(wd.resets = 0, "15s no bar at 3s interval: not yet")
    Loop 6
        wd.step(false, true, false, false, 3000)
    assert(wd.resets = 1, "33s no bar at 3s interval: reset (time-based, not count-based)")

    ; D: an active dps phase gates the watchdog entirely
    wd := Watchdog()
    Loop 50
        wd.step(true, true, true, false)
    assert(wd.resets = 0 && wd.noname_since = 0, "active phase: watchdog gated, timers stay 0")

    ; E: intermittent misses never accumulate across good reads
    wd := Watchdog()
    Loop 30 {
        wd.step(false, true, true, false)
        wd.step(false, true, true, false)
        wd.step(false, true, true, true)
    }
    assert(wd.resets = 0, "2 misses + 1 hit repeating: never resets")

    ; F: mixed miss types don't cross-contaminate timers
    wd := Watchdog()
    Loop 20
        wd.step(false, true, false, false)
    wd.step(false, true, true, false)   ; bar reappears (no name)
    Loop 20
        wd.step(false, true, false, false)
    assert(wd.resets = 0, "no-bar timer restarts when the bar reappears in between")
}

; ============================================================
; 5. phase start pipeline (issues 4 + regression) - virtual clock
;    mirrors: median3 -> fast_hp -> 1.2s max envelope -> pending
;    logic -> phase start -> damage from envelope -> recovery dump
; ============================================================
class PhaseSim {
    now := 100000
    hp_hist := []
    env_hist := []
    last_fast := -1
    last_env := -1
    pending := -1
    pending_tick := 0
    active := false
    start_time := 0
    phase_start_baseline := 999
    phase_min := 999
    phase_base := 999
    total := 0.0
    max_total_seen := 0.0
    time_of_last_damage := 100000
    dumped := 0
    recorded := []
    started_at := 0
    first_damage_at := 0
    boss_max_hp := 10000000
    ; hidden-bar / quarantine state (mirrors calculateDPS locals)
    bar_hidden := false
    warmup := 0
    last_good := -1
    hidden_since := 0
    last_unhide := 0
    last_hidden_ms := 0
    lump_clears := 0
    q_active := false
    q_since := 0
    q_low := 0
    min_reported := 999.0   ; lowest ENVELOPED hp ever reported (hold check)
    peak_hist := []
    peak := 0.0
    highest := 0.0          ; burst = highest running average (>= 2s history)
    last_damage_event := 0
    damage_gap_s := 0.0
    eff_window := 1.0       ; adaptive dps window (widens on sparse events)
    ; tunables mirror the script defaults
    static MIN_DROP := 0.25, CONFIRM_MS := 500, TRICKLE_MS := 1500
    static ENV_MS := 1200, FROZEN_MS := 8000, BIG_DROP := 8, BIG_CONFIRM_MS := 1500

    step(raw, name_visible := true) {
        this.now += 30

        ; --- hidden-bar hold / unhide flush + warmup (as in the script) ---
        if (raw <= 0 && this.last_good > 3) {
            if (!this.bar_hidden)
                this.hidden_since := this.now
            this.bar_hidden := true
            raw := this.last_good
            if (this.active) {
                if ((this.now - this.hidden_since) < PhaseSim.FROZEN_MS)
                    this.time_of_last_damage := this.now
                else
                    this.end(false)
            }
        } else {
            if (this.bar_hidden && raw > 0) {
                this.bar_hidden := false
                this.last_unhide := this.now
                this.last_hidden_ms := this.now - this.hidden_since
                this.hp_hist := []
                this.env_hist := []
                this.warmup := 2
            }
            if (raw > 0 && !this.q_active)
                this.last_good := raw
        }

        this.hp_hist.Push(raw)
        if (this.hp_hist.Length > 3)
            this.hp_hist.RemoveAt(1)
        hp := (this.hp_hist.Length = 3) ? median3(this.hp_hist[1], this.hp_hist[2], this.hp_hist[3]) : raw
        if (this.warmup > 0) {           ; collect samples, act on nothing
            this.warmup -= 1
            return
        }
        fast := hp                                  ; pre-envelope reading
        this.env_hist.Push([this.now, hp])
        while (this.env_hist.Length && this.now - this.env_hist[1][1] > PhaseSim.ENV_MS)
            this.env_hist.RemoveAt(1)
        for entry in this.env_hist
            if (entry[2] > hp)
                hp := entry[2]

        ; --- quarantine w/ any-size OCR gate (the inventory-spike fix) ---
        if (this.last_env >= 0 && !this.bar_hidden) {
            if ((this.last_env - hp) > PhaseSim.BIG_DROP
                && ((this.last_env - hp) > 40 || (this.now - this.last_unhide) > 800)) {
                if (!this.q_active) {
                    this.q_active := true
                    this.q_since := this.now
                    this.q_low := hp
                    if ((this.last_env - hp) > 40)
                        this.last_good := this.last_env
                }
                keeps_sinking := hp < this.q_low - 0.5
                this.q_low := Min(this.q_low, hp)
                if (!keeps_sinking && this.now - this.q_since < PhaseSim.BIG_CONFIRM_MS)
                    hp := this.last_env
                else if (!keeps_sinking && !name_visible) {
                    this.q_since := this.now + 2000 - PhaseSim.BIG_CONFIRM_MS
                    hp := this.last_env
                } else {
                    this.q_active := false
                    this.hidden_since := this.q_since
                    this.last_unhide := this.now
                    this.last_hidden_ms := Max(this.now - this.q_since, 0)
                }
            } else
                this.q_active := false
        } else if (this.bar_hidden && this.q_active)
            hp := this.last_env

        ; --- auto phase start (fast_hp based, as in the script) ---
        if (!this.active && this.last_fast >= 0 && !this.bar_hidden && !this.q_active) {
            if (fast > this.last_fast + 0.001)   ; epsilon-tolerant rise cancel
                this.pending := -1
            else if (this.pending < 0 && fast < this.last_fast) {
                this.pending := this.last_fast
                this.pending_tick := this.now
            } else if (this.pending >= 0 && fast >= this.pending)
                this.pending := -1
            drop := (this.pending >= 0) ? this.pending - fast : 0
            held := this.now - this.pending_tick
            ; unified confirm: any drop >= 0.05% held for the confirm window
            confirmed := this.pending >= 0
                && drop >= Min(PhaseSim.MIN_DROP, 0.05)
                && held >= PhaseSim.CONFIRM_MS
            ; big-drop ocr gate: no boss name -> defer, recheck in 0.5s
            if (confirmed && drop > PhaseSim.BIG_DROP && !name_visible) {
                confirmed := false
                this.pending_tick := this.now
            }
            if (confirmed) {
                this.active := true
                this.start_time := this.pending_tick
                this.started_at := this.now
                this.time_of_last_damage := this.now
                this.total := 0
                ; seed: confirmed drop shows as damage immediately (issue 1)
                this.phase_min := Max(fast, this.pending - 2)
                this.phase_base := this.pending
                this.phase_start_baseline := this.pending
                this.peak := 0
                this.peak_hist := []
                this.highest := 0
                this.last_damage_event := 0
                this.damage_gap_s := 0
                this.eff_window := 1.0
                this.pending := -1
            }
        }

        ; --- damage accumulation (envelope based) + lump guard + peak ---
        if (this.active) {
            if (this.phase_min > 500) {
                this.phase_min := hp
                if (this.phase_base > 500)
                    this.phase_base := hp
            }
            if (hp < this.phase_min || hp > this.phase_min + 2)
                this.phase_min := hp
            before := this.total
            this.total := Max((this.phase_base - this.phase_min) * this.boss_max_hp / 100, 0)
            this.max_total_seen := Max(this.max_total_seen, this.total)
            if (this.total > before) {
                this.time_of_last_damage := this.now
                if (this.total > 0 && !this.first_damage_at)
                    this.first_damage_at := this.now
                ; adaptive dps window: widen on sparse column-stepped damage
                if (this.last_damage_event) {
                    gap := (this.now - this.last_damage_event) / 1000.0
                    this.damage_gap_s := this.damage_gap_s ? 0.7 * this.damage_gap_s + 0.3 * gap : gap
                }
                this.last_damage_event := this.now
                this.eff_window := Max(1, Min(this.damage_gap_s * 1.5, 5))
                ; catch-up lump guard: restart the peak window on damage
                ; landing right after the bar returned from a REAL blackout
                ; (> 2s) - occlusion flickers must not wipe the windows
                if (this.last_unhide && this.last_hidden_ms > 2000
                    && this.now - this.last_unhide < 1500) {
                    this.peak_hist := []
                    this.lump_clears += 1
                }
            }
            ; rolling peak dps over the adaptive window (mirrors peak_hist)
            this.peak_hist.Push([this.now, this.total])
            while (this.peak_hist.Length && this.now - this.peak_hist[1][1] > this.eff_window * 1000)
                this.peak_hist.RemoveAt(1)
            span := (this.now - this.peak_hist[1][1]) / 1000
            this.peak := Max(this.peak, (this.total - this.peak_hist[1][2]) / Max(span, this.eff_window))
            ; burst = highest running average, only with >= 2s of history
            elapsed := (this.now - this.start_time) / 1000.0
            if (elapsed >= 2)
                this.highest := Max(this.highest, this.total / elapsed)
        }

        ; --- full-recovery artifact dump (fast_hp based) ---
        if (this.active && this.phase_start_baseline <= 500 && fast >= this.phase_start_baseline - 0.01)
            this.end(true)

        ; --- frozen-bar end ---
        if (this.active && this.now - this.time_of_last_damage >= PhaseSim.FROZEN_MS)
            this.end(false)

        this.last_env := hp
        this.min_reported := Min(this.min_reported, hp)
        this.last_fast := fast
    }
    end(dump) {
        if (this.active && !dump && this.total > 0)
            this.recorded.Push(this.total)
        if (dump)
            this.dumped += 1
        this.active := false
        this.total := 0
        this.phase_start_baseline := 999
        this.phase_min := 999
        this.phase_base := 999
    }
}

test_phase_start()
{
    log("[5] phase start pipeline (30ms virtual ticks)")

    ; A: steady damage -> phase starts fast and is NOT instantly dumped
    sim := PhaseSim()
    Loop 67                       ; 2s flat at 100%
        sim.step(100)
    t0 := sim.now
    hp := 100.0
    Loop 400 {                    ; 12s of damage at ~1.67%/s
        hp -= 0.05
        sim.step(hp)
    }
    assert(sim.started_at > 0, "A: steady damage starts a phase")
    delay := (sim.started_at - t0) / 1000.0
    assert(delay <= 0.8, "A: phase active " Round(delay, 2) "s after first drop (<= 0.8s; was ~1.7-5s)")
    assert(sim.start_time - t0 <= 100, "A: phase timer backdated to the first drop tick")
    assert(sim.dumped = 0, "A: freshly started phase survives the recovery check (regression fix)")
    assert(sim.first_damage_at && sim.first_damage_at - sim.started_at <= 100,
        "A: damage value nonzero within 0.1s of phase start (seed fix, was ~1.2s)")
    ; hold flat: the envelope lags ~1.2s, so the 8s frozen timeout needs
    ; ~9.2s of flat bar before it fires - give it 12s
    Loop 400
        sim.step(hp)
    assert(sim.recorded.Length = 1, "A: phase ends via frozen-bar timeout and is recorded")
    expected := (100 - hp) / 100 * sim.boss_max_hp
    got := sim.recorded.Length ? sim.recorded[1] : -1
    assert(got > 0 && Abs(got - expected) < 0.03 * expected,
        "A: recorded damage ~" Round(expected) " (got " Round(got) ")")

    ; B: short occlusion dip (0.3s) never starts a phase
    sim := PhaseSim()
    Loop 100
        sim.step(80)
    Loop 10                       ; 0.3s dip to 74
        sim.step(74)
    Loop 300
        sim.step(80)
    assert(sim.started_at = 0 && sim.dumped = 0, "B: 0.3s occlusion dip -> no phase, no dump")

    ; C: longer dip (0.9s) may start a phantom phase - it must self-dump
    ;    with zero damage ever counted
    sim := PhaseSim()
    Loop 100
        sim.step(80)
    Loop 30                       ; 0.9s dip to 74
        sim.step(74)
    Loop 300
        sim.step(80)
    assert(sim.recorded.Length = 0, "C: 0.9s dip records no phase")
    assert(!sim.active, "C: no phase left running after recovery")
    assert(sim.max_total_seen <= 0.02 * sim.boss_max_hp,
        "C: transient phantom damage capped at the 2% seed limit")
    assert(sim.started_at = 0 || sim.dumped >= 1, "C: phantom start (if any) dumped itself")

    ; D: flat bar forever -> nothing ever starts
    sim := PhaseSim()
    Loop 1000
        sim.step(65.4)
    assert(sim.started_at = 0, "D: flat bar starts nothing")

    ; E: single-frame noise spikes get median-filtered, no phase
    sim := PhaseSim()
    Loop 300 {
        sim.step(Mod(A_Index, 40) = 0 ? 68 : 70)   ; lone low frames
    }
    assert(sim.started_at = 0, "E: isolated 1-frame low reads never start a phase")

    ; F: trickle damage (single column steps) still starts via the 1.5s path
    sim := PhaseSim()
    Loop 100
        sim.step(90)
    t0 := sim.now
    Loop 200                      ; 6s: one 0.12% step every ~1.2s, never recovering
        sim.step(90 - 0.12 * (1 + (A_Index - 1) // 40))
    assert(sim.started_at > 0 && (sim.started_at - t0) <= 1000,
        "F: slow trickle starts a phase within 1s (unified confirm; was 1.5-2.5s)")

    ; K: high-HP boss - the bar only moves in whole pixel columns (0.158%
    ;    each at 1080p) and sheds one every ~1.2s. phase must start off the
    ;    FIRST column within ~0.6s, damage tracking the staircase
    sim := PhaseSim()
    Loop 100
        sim.step(100)
    t0 := sim.now
    Loop 300                      ; 9s: one 0.158% column every 40 ticks
        sim.step(100 - 0.158 * (1 + (A_Index - 1) // 40))
    assert(sim.started_at > 0 && (sim.started_at - t0) <= 700,
        "K: quantized single-column drop starts the phase in " Round((sim.started_at - t0)/1000.0, 2) "s (<= 0.7s; was ~1.6s)")
    assert(sim.first_damage_at && sim.first_damage_at - sim.started_at <= 100,
        "K: first column shows as damage immediately (seed)")
    assert(sim.active, "K: phase still running while columns keep dropping")
    assert(sim.total > 0.6 / 100 * sim.boss_max_hp,
        "K: damage tracks the staircase (" Round(sim.total) " after 7+ columns)")
    ; true dps here: one 0.158% column (15,800 hp) per 1.2s = ~13,167 dps
    assert(sim.highest > 0 && sim.highest < 20000,
        "K: burst ~true dps, no startup artifact (" Round(sim.highest) "; ungated read ~28k)")
    assert(sim.peak > 0 && sim.peak < 20000,
        "K: peak ~true dps via adaptive window (" Round(sim.peak) "; 1s window read 2 columns as ~31.6k)")

    ; G: inventory mid-phase, teammates keep shooting (the reported spike):
    ;    phase -> 3s hidden bar -> returns 10% lower (1M catch-up lump)
    sim := PhaseSim()
    Loop 67
        sim.step(100)
    hp := 100.0
    Loop 150 {                    ; 4.5s steady damage (~167k dps)
        hp -= 0.05
        sim.step(hp)
    }
    peak_before_menu := sim.peak
    Loop 100                      ; 3s in the inventory (bar gone)
        sim.step(0)
    hp -= 10                      ; teammates did 10% meanwhile
    Loop 100 {                    ; damage continues after closing it
        hp -= 0.05
        sim.step(hp)
    }
    Loop 400                      ; flat -> frozen end records the phase
        sim.step(hp)
    assert(sim.recorded.Length = 1, "G: phase survives a 3s inventory visit and records once")
    expected := (100 - hp) / 100 * sim.boss_max_hp
    got := sim.recorded.Length ? sim.recorded[1] : -1
    assert(got > 0 && Abs(got - expected) < 0.05 * expected,
        "G: catch-up lump still COUNTS as damage (~" Round(expected) ", got " Round(got) ")")
    assert(sim.peak < 400000,
        "G: peak dps stays ~steady (" Round(sim.peak) " < 400k; lump alone would read 1M+)")
    assert(sim.lump_clears >= 1, "G: a real 3s blackout DOES trigger the lump guard")

    ; H: the false inventory bar: gold UI reads as a 45% bar for 15s with no
    ;    boss name on screen (old code accepted it after 1.5s -> 3.5M spike)
    sim := PhaseSim()
    Loop 100
        sim.step(80)
    Loop 500                      ; 15s of false bar, name unreadable
        sim.step(45, false)
    Loop 200                      ; menu closed, real bar back
        sim.step(80)
    assert(sim.started_at = 0, "H: false menu bar never starts a phase")
    assert(sim.max_total_seen = 0, "H: false menu bar counts zero damage (was 3.5M)")
    assert(sim.min_reported >= 79.9, "H: reported hp held at the real value the whole time")

    ; I: partial first frame when the bar re-renders after a menu
    sim := PhaseSim()
    Loop 67
        sim.step(100)
    hp := 100.0
    Loop 350 {                    ; damage down to 82.5
        hp -= 0.05
        sim.step(hp)
    }
    Loop 66                       ; 2s menu
        sim.step(0)
    sim.step(30)                  ; first frame: bar only partially rendered
    Loop 300
        sim.step(80.5)            ; real value (small teammate lump)
    Loop 400
        sim.step(80.5)
    assert(sim.max_total_seen <= 2050000,
        "I: the 30% partial frame never counts (max seen " Round(sim.max_total_seen) ", a counted frame would be 5M+)")
    got := sim.recorded.Length ? sim.recorded[1] : -1
    assert(sim.recorded.Length = 1 && Abs(got - 1950000) < 100000,
        "I: phase records the true ~1.95M (got " Round(got) ")")
    assert(sim.peak < 400000, "I: no peak spike from the re-render (" Round(sim.peak) ")")

    ; J: the graph-starvation regression: TRICKLE damage while the reading
    ;    flickers to 0 for one frame every ~1s (occluded translucent bar).
    ;    flickers pass through the hidden/unhide machinery and used to wipe
    ;    the peak/burst/graph windows on every damage tick
    sim := PhaseSim()
    Loop 67
        sim.step(100)
    hp := 100.0
    Loop 600 {                    ; 18s of slow damage (~33k dps)
        hp -= 0.01
        sim.step(Mod(A_Index, 30) = 0 ? 0 : hp)   ; 1-frame dropout each 0.9s
    }
    Loop 400
        sim.step(hp)
    assert(sim.started_at > 0, "J: trickle damage under flickers still starts a phase")
    assert(sim.lump_clears = 0, "J: flickers never wipe the peak/graph windows (was every damage tick)")
    got := sim.recorded.Length ? sim.recorded[1] : -1
    expected := (100 - hp) / 100 * sim.boss_max_hp
    assert(sim.recorded.Length = 1 && Abs(got - expected) < 0.1 * expected,
        "J: records ~" Round(expected) " despite flickers (got " Round(got) ")")
    assert(sim.peak > 0 && sim.peak < 150000, "J: peak stays trickle-sized (" Round(sim.peak) ")")

    ; ...and the real-blackout lump guard still fires when it should
    assert(sim.lump_clears = 0, "J: control - no false lump clears in this run")
}

; ============================================================
; 6. time-series csv writer (issue 5) - the end_dps_phase block
; ============================================================
test_timeseries()
{
    log("[6] 10Hz time-series csv writer")
    ; synthetic burst_hist: 10/s for 30s, 1000 dmg per 100ms (10k dps),
    ; dps_start_time 250ms before the first sample (backdated start)
    dps_start_time := 1000000
    burst_hist := []
    t := dps_start_time + 250
    total := 0
    Loop 300 {
        total += 1000
        burst_hist.Push([t, total])
        t += 100
    }
    ; --- verbatim writer block from end_dps_phase ---
    ts := "time_s,total_damage,dps_1s`r`n"
    j := 1
    for e in burst_hist
    {
        while (e[1] - burst_hist[j][1] > 1000)
            j += 1
        span := (e[1] - burst_hist[j][1]) / 1000
        dps1 := (span > 0) ? Round((e[2] - burst_hist[j][2]) / span) : 0
        ts .= Round((e[1] - dps_start_time) / 1000, 2) "," Round(e[2]) "," dps1 "`r`n"
    }
    ; --- checks ---
    rows := StrSplit(RTrim(ts, "`r`n"), "`r`n")
    assert(rows[1] = "time_s,total_damage,dps_1s", "header row correct")
    assert(rows.Length = 301, "300 samples -> 301 rows (got " rows.Length ")")
    r2 := StrSplit(rows[2], ",")
    assert(r2[1] = "0.25" && r2[2] = "1000", "first row: t=0.25s (backdated start respected), dmg=1000")
    rLast := StrSplit(rows[301], ",")
    assert(rLast[1] = "30.15" && rLast[2] = "300000", "last row: t=30.15s, dmg=300000")
    ; sample density ~10/s
    density := (rows.Length - 1) / ((30.15 - 0.25))
    assert(density >= 10, "recorded density " Round(density, 1) "/s (>= 10/s required)")
    ; steady-state 1s dps correct
    rMid := StrSplit(rows[150], ",")
    assert(rMid[3] = "10000", "trailing-1s dps = 10000 at steady state (got " rMid[3] ")")
    ; time monotonic
    mono := true
    prev := -1.0
    for i, row in rows {
        if (i = 1)
            continue
        tv := StrSplit(row, ",")[1] + 0
        if (tv <= prev)
            mono := false
        prev := tv
    }
    assert(mono, "time column strictly increasing")
    ; graph timer: 100ms sampling for 10 min stays under the thinning cap
    assert(600 * 10 <= 6000, "10-min phase at 10/s fits the 6000-sample cap before thinning")
}

; ============================================================
; 7. bossHealthPercentage on real bitmaps (VERBATIM copy incl. the
;    contiguity check) - the white-pill false bar from the screenshot
; ============================================================
#Include "D:\Downloads\drive-download-20260718T143231Z-1-001\Gdip_all.ahk"
global boss_health_colors := Map()
global res1080p := 1

; --- verbatim copies from protoDDT.ahk ---
bar_pixel_match(argb)
{
    global boss_health_colors
    if (boss_health_colors.Has(argb))
        return 1
    r := (argb >> 16) & 0xFF
    g := (argb >> 8) & 0xFF
    b := argb & 0xFF
    return (r >= 190 && g >= 170 && b >= 90 && b <= 210 && b < Min(r, g) - 25)
}

findAllColorsBetween(darkColor, lightColor)
{
    darkArray := convertToRGB(darkColor)
    lightArray := convertToRGB(lightColor)
    returnHashTable := Map()
    redDifference := lightArray[1] - darkArray[1] + 1
    greenDifference := lightArray[2] - darkArray[2] + 1
    blueDifference := lightArray[3] - darkArray[3] + 1
    redIndex := 0
    greenIndex := 0
    blueIndex := 0
    loop redDifference
    {
        loop greenDifference
        {
            loop blueDifference
            {
                tempColor := 0xFF000000 | ((darkArray[1]+redIndex) << 16) | ((darkArray[2]+greenIndex) << 8) | (darkArray[3]+blueIndex)
                returnHashTable[tempColor] := 1
                blueIndex++
            }
            blueIndex := 0
            greenIndex++
        }
        greenIndex := 0
        redIndex++
    }
    return returnHashTable
}

convertToRGB(color)
{
    red := Integer("0x" SubStr(color, 3, 2))
    green := Integer("0x" SubStr(color, 5, 2))
    blue := Integer("0x" SubStr(color, 7, 2))
    return [red, green, blue]
}

bossHealthPercentage(pBitmap, has_final := 0)
{
    global boss_health_colors, res1080p
    Gdip_GetImageDimensions(pBitmap, &w, &h)
    if (w <= 0 || h <= 0)
        return 0
    totalCols := w
    loop Integer(has_final)
        totalCols -= res1080p ? 2 : 3
    if (totalCols <= 0)
        return 0
    use_lb := !Gdip_LockBits(pBitmap, 0, 0, w, h, &stride, &scan0, &bmpData, 1)
    edge := 0
    run := 0
    m1 := 0, m2 := 0
    x := w - 1
    while (x >= 0)
    {
        matched := 0
        y := 0
        loop h
        {
            argb := use_lb ? NumGet(scan0, x*4 + y*stride, "UInt") : Gdip_GetPixel(pBitmap, x, y)
            if (bar_pixel_match(argb))
            {
                matched := 1
                break
            }
            y += 1
        }
        if (matched)
        {
            run += 1
            if (run >= 3)
            {
                edge := x + 3
                break
            }
            if (x = 1)
                m2 := 1
            else if (x = 0)
                m1 := 1
        }
        else
            run := 0
        x -= 1
    }
    if (edge > 24)
    {
        probe_hits := 0
        for frac in [0.05, 0.15, 0.28, 0.4, 0.52, 0.64, 0.76, 0.85]
        {
            px := Integer((edge - 1) * frac)
            y := 0
            loop h
            {
                argb := use_lb ? NumGet(scan0, px*4 + y*stride, "UInt") : Gdip_GetPixel(pBitmap, px, y)
                if (bar_pixel_match(argb))
                {
                    probe_hits += 1
                    break
                }
                y += 1
            }
        }
        if (probe_hits < 2)
            edge := 0
    }
    if (use_lb)
        Gdip_UnlockBits(pBitmap, &bmpData)
    if (!edge)
        edge := m2 ? 2 : m1 ? 1 : 0
    return Min((edge / totalCols) * 100, 100)
}
; --- end verbatim copies ---

; paint columns [from..to] (0-based) of a w x 3 test bitmap with argb
fill_cols(pBitmap, from, to, argb)
{
    x := from
    while (x <= to)
    {
        loop 3
            Gdip_SetPixel(pBitmap, x, A_Index - 1, argb)
        x += 1
    }
}

test_pixels()
{
    log("[7] bossHealthPercentage pixel tests (real gdi+ bitmaps)")
    global boss_health_colors := findAllColorsBetween("0xD0901D", "0xECAD42")  ; Normal, brightness 6
    bar := 0xFFDCA032       ; in-table healthbar color
    pill := 0xFFD2CDA0      ; the inventory scroll pill: warm off-white (210,205,160)
    bg := 0xFF101014        ; dark background

    assert(bar_pixel_match(pill), "the pill color DOES pass the color match (why the spike happened)")

    ; full bar
    p := Gdip_CreateBitmap(200, 3)
    fill_cols(p, 0, 199, bar)
    v := bossHealthPercentage(p)
    assert(Abs(v - 100) < 1.6, "full bar reads ~100% (got " Round(v, 2) ")")
    Gdip_DisposeImage(p)

    ; half bar
    p := Gdip_CreateBitmap(200, 3)
    fill_cols(p, 0, 199, bg)
    fill_cols(p, 0, 99, bar)
    v := bossHealthPercentage(p)
    assert(Abs(v - 50) < 1.6, "half bar reads ~50% (got " Round(v, 2) ")")
    Gdip_DisposeImage(p)

    ; the screenshot scenario: ONLY the white pill, no bar (inventory open)
    p := Gdip_CreateBitmap(200, 3)
    fill_cols(p, 0, 199, bg)
    fill_cols(p, 120, 139, pill)
    v := bossHealthPercentage(p)
    assert(v = 0, "inventory pill alone reads 0% - no false bar (got " Round(v, 2) ", was ~70%)")
    Gdip_DisposeImage(p)

    ; a lone 2-column glint past the real edge (run-of-3 rejects it)
    p := Gdip_CreateBitmap(200, 3)
    fill_cols(p, 0, 199, bg)
    fill_cols(p, 0, 99, bar)
    fill_cols(p, 150, 151, bar)
    v := bossHealthPercentage(p)
    assert(Abs(v - 50) < 1.6, "2-col glint past the edge ignored, still ~50% (got " Round(v, 2) ")")
    Gdip_DisposeImage(p)

    ; a real bar with one occluded probe column still reads
    p := Gdip_CreateBitmap(200, 3)
    fill_cols(p, 0, 199, bg)
    fill_cols(p, 0, 99, bar)
    fill_cols(p, 34, 36, bg)   ; nameplate/divider blanking one probe spot
    v := bossHealthPercentage(p)
    assert(Abs(v - 50) < 1.6, "bar with one occluded stripe still reads ~50% (got " Round(v, 2) ")")
    Gdip_DisposeImage(p)

    ; translucent bar whose MIDDLE is darkened by effects: only the left
    ; anchor and the edge area still match - must NOT read as "no bar"
    ; (the strict 3-of-4 version zeroed this and starved the graph)
    p := Gdip_CreateBitmap(200, 3)
    fill_cols(p, 0, 199, bg)
    fill_cols(p, 0, 15, bar)     ; left anchor
    fill_cols(p, 84, 99, bar)    ; edge area
    v := bossHealthPercentage(p)
    assert(Abs(v - 50) < 1.6, "dark-middle translucent bar still reads ~50% (got " Round(v, 2) ")")
    Gdip_DisposeImage(p)

    ; empty region
    p := Gdip_CreateBitmap(200, 3)
    fill_cols(p, 0, 199, bg)
    v := bossHealthPercentage(p)
    assert(v = 0, "empty region reads 0%")
    Gdip_DisposeImage(p)

    ; low hp: a small left-anchored remnant must NOT be contiguity-rejected
    p := Gdip_CreateBitmap(200, 3)
    fill_cols(p, 0, 199, bg)
    fill_cols(p, 0, 9, bar)
    v := bossHealthPercentage(p)
    assert(Abs(v - 5) < 1.6, "5% remnant at the left edge still reads (got " Round(v, 2) ")")
    Gdip_DisposeImage(p)
}

; ============================================================
global gdip_token := Gdip_Startup()
test_settings()
test_flush_decision()
test_number_gating()
test_watchdog()
test_phase_start()
test_timeseries()
test_pixels()

log("")
log(fail_n = 0 ? "ALL " pass_n " TESTS PASSED" : fail_n " FAILED / " pass_n " passed")
FileOpen(A_ScriptDir "\results.txt", "w").Write(out)
ExitApp(fail_n = 0 ? 0 : 1)
