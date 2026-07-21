#Requires AutoHotkey v2.0
#SingleInstance Force
SendMode "Input"
SetWorkingDir A_ScriptDir

#Include "%A_ScriptDir%\Gdip_all.ahk"
#Include "%A_ScriptDir%\OCR.ahk"

; only meaningful if the script is ever compiled to an exe (bundles the two
; data files); harmless no-ops when run as a plain .ahk
FileInstall "settings.txt", A_ScriptDir "\settings.txt"
FileInstall "Boss_full_name+HP.txt", A_ScriptDir "\Boss_full_name+HP.txt"

pToken := Gdip_Startup()

global dps_phase_active := false
global boss_health_pool := Map()
global boss_final_stand := Map()
global boss_nobar := Map()
global boss_variant := Map()
load_boss_data()

; parses Boss_full_name+HP.txt, the single boss data file. entry lines look
; like: "Exact On-Screen Name" = HP ,breaks - anything else is a section
; header; headers containing (Epic) or PANTHEON tag following entries as
; variants, keyed "Name [Epic]" / "Name [Pantheon]" so they can coexist with
; their regular counterparts. "(No Boss HP bar)" excludes an entry from OCR.
load_boss_data()
{
    global boss_health_pool := Map(), boss_final_stand := Map()
    global boss_nobar := Map(), boss_variant := Map()
    variant := "normal"
    content := FileRead(A_ScriptDir "\Boss_full_name+HP.txt", "UTF-8")
    Loop Parse content, "`n", "`r"
    {
        line := Trim(RegExReplace(A_LoopField, "[\x{200B}\x{FEFF}]"))
        if (line = "" || SubStr(line, 1, 1) = ";")
            continue
        if !RegExMatch(line, '^"([^"]+)"\s*=?\s*(.*)$', &entry)
        {
            ; section header: switches the variant for the entries below it
            if InStr(line, "(Epic)")
                variant := "epic"
            else if InStr(StrUpper(line), "PANTHEON")
                variant := "pantheon"
            else
                variant := "normal"
            continue
        }
        name := Trim(entry[1])
        rest := entry[2]
        hp := 0
        if RegExMatch(rest, "([\d,]+)", &hpMatch)
            hp := StrReplace(hpMatch[1], ",", "") + 0
        breaks := 0
        if RegExMatch(rest, ",\s*(\d+)\s*$", &breaksMatch)
            breaks := breaksMatch[1] + 0
        nobar := RegExMatch(rest, "i)no\s+(actual\s+)?boss\s+hp\s+bar") ? 1 : 0
        key := name (variant = "pantheon" ? " [Pantheon]" : variant = "epic" ? " [Epic]" : "")
        boss_health_pool[key] := hp
        boss_final_stand[key] := breaks
        boss_nobar[key] := nobar
        boss_variant[key] := variant
    }
}

global settingsGui := Gui(, "Settings")
settingsGui.Add("DropDownList", "w260 vBossName")
settingsGui.Add("Button", , "OK").OnEvent("Click", ButtonOK)
settingsGui.Add("Text", "y+12", "— Measure boss HP —")
settingsGui.Add("Text", , "Damage of one hit:")
settingsGui.Add("Edit", "w150 vMeasureDamage")
settingsGui.Add("Text", , "Save as boss (optional):")
settingsGui.Add("Edit", "w150 vMeasureName")
settingsGui.Add("Button", , "Measure").OnEvent("Click", ButtonMeasure)
settingsGui.Add("Text", "y+12", "— Screen setup —")
settingsGui.Add("Button", , "Calibrate bar location").OnEvent("Click", calibrate_bar)
settingsGui.Add("Button", "x+8", "Reset calibration").OnEvent("Click", flush_calibration)

global quickGui := ""  ; the F2 quick menu, built lazily on first open
global ColorBlind := "Normal"
global brightnessLevel := 7
global quickMenuHotkey := "F2"    ; the always-available options menu
global settingsGUIHotkey := "F6"  ; boss picker / measure / calibrate window
global damageTestHotkey := ""     ; legacy 90s damage test, unbound by default
global startAndStopDPS := "F3"
global detectBossHotkey := "F7"
global graphCurvesHotkey := "F8"
global graphEditHotkey := "F9"
global encounterContextHotkey := "F10"
global csvLogHotkey := "F11"
global copySummaryHotkey := "F12"
global encounterContext := "normal"  ; normal | epic | pantheon - picks between same-named variants
global reloadScriptHotkey := "F5"
global closeScriptHotkey := "F4"
global includeDPSCalculations := 1
global DPSatCrosshair := 0
global includeEstimatedBossHealth := 1
global includeBurstAndSustainedSpecifiers := 1
global textColor := "white"
global textFont := "Helvetica"
global boldText := 1
global showDamageDealt := 0
global decimalPlacesHealthPercentage := 2
global showDamageDuration := 0
global estimateTimeToKill := 0
global res1080p := 0
global autoDetectBoss := 1             ; scan for the boss name automatically when a bar is visible
global autoDetectIntervalSeconds := 1
global tracking_active := false
global current_boss := ""
global switch_to_boss := ""            ; set by detection to retarget the running tracker
global maxInstantDropPercent := 8      ; single-tick drops beyond this are visual artifacts until proven real
global bigDropConfirmSeconds := 1.5    ; how long a collapse must persist before it's accepted as damage
global phaseStartMinDrop := 0.25       ; % the bar must drop before a phase auto-starts (~2 columns)
global phaseStartConfirmSeconds := 0.5 ; how long the drop must persist before it counts
global phaseEndFrozenSeconds := 8      ; frozen-bar time that ends a phase
global showDPSGraph := 1
global graph_curves := 7          ; bitmask: 1 = real-time dps, 2 = peak dps, 4 = total damage
global dpsWindowSeconds := 1      ; window for the real-time dps curve/label
global dps_effective_window := 1  ; auto-widened on sparse (column-stepped) damage
global graphLayoutOverride := ""  ; "x|y|w|h" saved from in-game edit mode
global healthbarLocationOverride := ""  ; "x|y|w|h" written by the calibration wizard
global bossnameLocationOverride := ""
global calibrateHotkey := ""            ; unbound unless set in settings
global edit_mode := 0
global graph_rebuilding := 0      ; surface is being torn down / rebuilt - don't render
global manualDPSPhases := 0
global isUltraWide := 0
global boss_health_colors := Map()
global separateWindow := 0

get_settings()

global change_phase := 0
global time_to_kill := 0
global current_dps := 0
global elapsed_time := 0
global percent_dealt := 0
global stop_loop := 0
global boss_max_hp := 0
; per-phase record fields, maintained by calculateDPS and written to
; phases.csv by end_dps_phase when a phase ends naturally
global phase_peak_dps := 0
global phase_hp_start := 0
global phase_hp_end := 0
global phase_killed := 0
global savePhaseHistory := 1  ; write phases.csv + graph png + best records
global enableCsvLogger := 1   ; allow the F11 measurement logger
global phase_ttfd := 0        ; seconds from bar appearing to the phase starting
global burst_hist := []       ; [tick, total] pairs (~10/s) for burst-window stats
global last_phase_summary := ""
global healthbar_location := "858|1302|845|3"
global bossname_location := "858|1310|600|55"  ; region where the boss name renders, under the bar
if (res1080p)
{
    healthbar_location := "644|976|634|3"  ; 3 rows: a 1px obstruction line can't blank a column
    bossname_location := "644|982|450|40"
}

global bossGui
if (separateWindow)
{
    bossGui := Gui("+AlwaysOnTop +LastFound +E0x20")
    bossGui.BackColor := "010101"
    bossGui.SetFont("s24 c" textColor (boldText ? " Bold" : ""), textFont)

    width := 420

    ; big percent on top, total health under it
    bossGui.Add("Text", "x10 y10 w400 h44 vPercentHealth +0x200 +Center")
    if (includeEstimatedBossHealth) {
        bossGui.SetFont("s14")
        bossGui.Add("Text", "x10 y58 w400 h26 vTotalHealth +0x200 +Center")
    }

    ; label:value grid, two columns: burst / sustained then duration / time to kill
    ; the numbers are tied to the specifiers: no labels, no numbers
    yRow := 96
    if (includeDPSCalculations && includeBurstAndSustainedSpecifiers) {
        bossGui.SetFont("s11")
        bossGui.Add("Text", "x10 y" yRow " w195 h16 vGUI_burst +0x200 +Center")
        bossGui.Add("Text", "x215 y" yRow " w195 h16 vGUI_sustained +0x200 +Center")
        bossGui.SetFont("s16")
        bossGui.Add("Text", "x10 y" (yRow+18) " w195 h30 vHighestDPS +0x200 +Center")
        bossGui.Add("Text", "x215 y" (yRow+18) " w195 h30 vAverageDPS +0x200 +Center")
        yRow += 56
    }
    if (showDamageDuration || estimateTimeToKill) {
        bossGui.SetFont("s11")
        if (showDamageDuration)
            bossGui.Add("Text", "x10 y" yRow " w195 h16 vGUI_dps_phase +0x200 +Center")
        if (estimateTimeToKill)
            bossGui.Add("Text", "x215 y" yRow " w195 h16 vGUI_time_to_kill +0x200 +Center")
        bossGui.SetFont("s16")
        if (showDamageDuration)
            bossGui.Add("Text", "x10 y" (yRow+18) " w195 h30 vDPSDuration +0x200 +Center")
        if (estimateTimeToKill)
            bossGui.Add("Text", "x215 y" (yRow+18) " w195 h30 vTimeToKill +0x200 +Center")
        yRow += 56
    }
    height := yRow + 8

    ; tracker state dot: gray idle, blue boss locked, orange phase running
    bossGui.SetFont("s9 c777777")
    bossGui.Add("Text", "x16 y16 w16 h16 vdot_idle +0x200 +Center", Chr(0x25CF))
    bossGui.SetFont("c6FB7FF")
    bossGui.Add("Text", "x16 y16 w16 h16 vdot_locked +0x200 +Center Hidden", Chr(0x25CF))
    bossGui.SetFont("cE8A032")
    bossGui.Add("Text", "x16 y16 w16 h16 vdot_phase +0x200 +Center Hidden", Chr(0x25CF))

    bossGui.Title := "DDT"
    bossGui.Show("w" width " h" height)
}
Else if (res1080p)
{
    bossGui := Gui("-Caption +AlwaysOnTop +ToolWindow +LastFound +E0x20")
    bossGui.BackColor := "010101"
    bossGui.SetFont("s12 c" textColor (boldText ? " Bold" : ""), textFont)

    ; health cluster (center): percent above total health
    bossGui.SetFont("s14")
    bossGui.Add("Text", "x860 y1012 w200 h26 vPercentHealth +0x200 +Center")
    bossGui.SetFont("s11")
    bossGui.Add("Text", "x810 y1042 w300 h20 vTotalHealth +0x200 +Center")

    ; phase cluster (right): labels above values, aligned columns
    bossGui.SetFont("s10")
    bossGui.Add("Text", "x1320 y1012 w160 h18 vGUI_dps_phase +0x200 +Center")
    bossGui.Add("Text", "x1520 y1012 w160 h18 vGUI_time_to_kill +0x200 +Center")
    bossGui.SetFont("s12")
    bossGui.Add("Text", "x1320 y1032 w160 h24 vDPSDuration +0x200 +Center")
    bossGui.Add("Text", "x1520 y1032 w160 h24 vTimeToKill +0x200 +Center")

    ; dps cluster flanking the health block: labels above values
    bossGui.SetFont("s10")
    bossGui.Add("Text", "x660 y1012 w200 h18 vGUI_burst +0x200 +Center")
    bossGui.Add("Text", "x1060 y1012 w200 h18 vGUI_sustained +0x200 +Center")

    if (DPSatCrosshair)
    {
        bossGui.SetFont("s8")
        bossGui.Add("Text", "x760 y530 w200 h20 vHighestDPS +0x200 +Center")
        bossGui.Add("Text", "x960 y530 w200 h20 vAverageDPS +0x200 +Center")
    }
    Else
    {
        bossGui.SetFont("s12")
        bossGui.Add("Text", "x660 y1032 w200 h24 vHighestDPS +0x200 +Center")
        bossGui.Add("Text", "x1060 y1032 w200 h24 vAverageDPS +0x200 +Center")
    }

    ; tracker state dot: gray idle, blue boss locked, orange phase running
    bossGui.SetFont("s9 c777777")
    bossGui.Add("Text", "x842 y1016 w16 h16 vdot_idle +0x200 +Center", Chr(0x25CF))
    bossGui.SetFont("c6FB7FF")
    bossGui.Add("Text", "x842 y1016 w16 h16 vdot_locked +0x200 +Center Hidden", Chr(0x25CF))
    bossGui.SetFont("cE8A032")
    bossGui.Add("Text", "x842 y1016 w16 h16 vdot_phase +0x200 +Center Hidden", Chr(0x25CF))

    bossGui.Title := "DDT"
    bossGui.Show("x0 y0 h1080 NoActivate")
}
Else
{
    bossGui := Gui("-Caption +AlwaysOnTop +ToolWindow +LastFound +E0x20")
    bossGui.BackColor := "010101"
    bossGui.SetFont("s18 c" textColor (boldText ? " Bold" : ""), textFont)

    ; health cluster (center): big percent above total health
    bossGui.SetFont("s20")
    bossGui.Add("Text", "x200 y1342 w400 h40 vPercentHealth +0x200 +Center")
    bossGui.SetFont("s14")
    bossGui.Add("Text", "x200 y1386 w400 h30 vTotalHealth +0x200 +Center")

    ; phase cluster (right): labels above values, aligned columns
    bossGui.SetFont("s12")
    bossGui.Add("Text", "x950 y1342 w200 h24 vGUI_dps_phase +0x200 +Center")
    bossGui.Add("Text", "x1150 y1342 w200 h24 vGUI_time_to_kill +0x200 +Center")
    bossGui.SetFont("s16")
    bossGui.Add("Text", "x950 y1368 w200 h36 vDPSDuration +0x200 +Center")
    bossGui.Add("Text", "x1150 y1368 w200 h36 vTimeToKill +0x200 +Center")

    ; dps cluster flanking the health block: labels above values
    bossGui.SetFont("s12")
    bossGui.Add("Text", "x0 y1342 w200 h24 vGUI_burst +0x200 +Center")
    bossGui.Add("Text", "x600 y1342 w200 h24 vGUI_sustained +0x200 +Center")

    if (DPSatCrosshair)
    {
        bossGui.SetFont("s12")
        bossGui.Add("Text", "x190 y690 w200 h50 vHighestDPS +0x200 +Center")
        bossGui.Add("Text", "x410 y690 w200 h50 vAverageDPS +0x200 +Center")
    }
    Else
    {
        bossGui.SetFont("s16")
        bossGui.Add("Text", "x0 y1368 w200 h36 vHighestDPS +0x200 +Center")
        bossGui.Add("Text", "x600 y1368 w200 h36 vAverageDPS +0x200 +Center")
    }

    ; tracker state dot: gray idle, blue boss locked, orange phase running
    bossGui.SetFont("s9 c777777")
    bossGui.Add("Text", "x184 y1352 w16 h16 vdot_idle +0x200 +Center", Chr(0x25CF))
    bossGui.SetFont("c6FB7FF")
    bossGui.Add("Text", "x184 y1352 w16 h16 vdot_locked +0x200 +Center Hidden", Chr(0x25CF))
    bossGui.SetFont("cE8A032")
    bossGui.Add("Text", "x184 y1352 w16 h16 vdot_phase +0x200 +Center Hidden", Chr(0x25CF))

    bossGui.Title := "DDT"
    if (isUltraWide)
    {
        healthbar_location := "1298|1302|845|3"
        bossname_location := "1298|1310|600|55"
        bossGui.Show("x1320 y0 h1440 NoActivate")
    }
    Else
        bossGui.Show("x880 y0 h1440 NoActivate")
}

; calibrated regions beat the per-resolution defaults (incl. the ultrawide
; reassignment above)
if (healthbarLocationOverride != "")
    healthbar_location := healthbarLocationOverride
if (bossnameLocationOverride != "")
    bossname_location := bossnameLocationOverride

if !(separateWindow)
    WinSetTransColor("010101 255", bossGui.Hwnd)

if (showDamageDuration)
    gset("GUI_dps_phase", "DPS Phase:")
if (estimateTimeToKill)
    gset("GUI_time_to_kill", "Time To Kill:")

if (includeDPSCalculations)
{
    if (includeBurstAndSustainedSpecifiers && !(DPSatCrosshair))
    {
        gset("GUI_burst", "Burst:")
        gset("GUI_sustained", "Sustained:")
    }
}

if !(separateWindow)
    SetTimer(check_destiny_open, 500)
global currently_shown := 1

; ---- dps graph window (layered, click-through, drawn with gdi+) ----
; sits directly above the DPS Phase / Time To Kill cluster, right of the
; healthbar's end so it can't clip into the bar
global graph_w := 360, graph_h := 140
global graph_x := 1320, graph_y := 864  ; 1080p: cluster at x1320 y1012, bar ends x1278
if (!separateWindow && !res1080p)
{
    graph_w := 400, graph_h := 150
    graph_x := (isUltraWide ? 1320 : 880) + 950  ; cluster x950 in window coords, bar ends x1703 screen
    graph_y := 1184                              ; bottom lands ~8px above the y1342 labels
}
else if (separateWindow)
{
    graph_w := 300, graph_h := 100  ; docked under the separate window
}
; a layout saved from in-game edit mode (F9) overrides the defaults
if (graphLayoutOverride != "")
{
    layoutParts := StrSplit(graphLayoutOverride, "|")
    if (layoutParts.Length = 4)
    {
        graph_x := layoutParts[1]+0, graph_y := layoutParts[2]+0
        graph_w := Max(layoutParts[3]+0, 100), graph_h := Max(layoutParts[4]+0, 60)
    }
}
global graphGui := "", graph_hdc := 0, graph_hbm := 0, graph_obm := 0, graph_G := 0
global graph_samples := []
global graph_visible := false
global graph_linger_until := 0
; gdi+ needs a bare family name ("Microsoft YaHei UI"), not a gui font string
; ("Microsoft YaHei UI Bold") - resolve one for the graph labels
global graph_font := "Arial"
for candidate in [textFont, RegExReplace(textFont, "i)\s+(Bold|Italic|Regular)$", "")]
{
    hFam := Gdip_FontFamilyCreate(candidate)
    if (hFam)
    {
        Gdip_DeleteFontFamily(hFam)
        graph_font := candidate
        break
    }
}
if (showDPSGraph)
    init_graph()

; builds the graph window + drawing surface; also called when the graph is
; enabled live from the quick menu
init_graph()
{
    global
    if IsObject(graphGui)
        return
    graphGui := Gui("-Caption +AlwaysOnTop +ToolWindow +E0x80000 +E0x20")
    graphGui.Show("NA x" graph_x " y" graph_y " w" graph_w " h" graph_h)
    graphGui.Hide()
    graph_hbm := CreateDIBSection(graph_w, graph_h)
    graph_hdc := CreateCompatibleDC()
    graph_obm := SelectObject(graph_hdc, graph_hbm)
    graph_G := Gdip_GraphicsFromHDC(graph_hdc)
    Gdip_SetSmoothingMode(graph_G, 4)
    SetTimer(graph_tick, 100)  ; ~10 samples/s; the dps curve stays readable
                               ; because it's windowed over dpsWindowSeconds
    OnMessage(0x201, graph_click)  ; WM_LBUTTONDOWN: drag in edit mode
}

if (autoDetectBoss)
    SetTimer(auto_detect_tick, autoDetectIntervalSeconds * 1000)

return

get_settings()
{
    global reloadScriptHotkey, closeScriptHotkey, settingsGUIHotkey, startAndStopDPS, detectBossHotkey
    global manualDPSPhases, includeDPSCalculations, DPSatCrosshair, decimalPlacesHealthPercentage
    global includeEstimatedBossHealth, showDamageDealt, showDamageDuration, estimateTimeToKill
    global includeBurstAndSustainedSpecifiers, textColor, textFont, separateWindow, boldText
    global res1080p, isUltraWide, brightnessLevel, ColorBlind, boss_health_colors
    global phaseStartMinDrop, phaseStartConfirmSeconds, phaseEndFrozenSeconds, showDPSGraph
    global maxInstantDropPercent, bigDropConfirmSeconds
    global autoDetectBoss, autoDetectIntervalSeconds
    global graphCurvesHotkey, graphEditHotkey, graph_curves, graphLayoutOverride
    global encounterContextHotkey, encounterContext, csvLogHotkey, dpsWindowSeconds
    global copySummaryHotkey, healthbarLocationOverride, bossnameLocationOverride, calibrateHotkey
    global savePhaseHistory, enableCsvLogger, quickMenuHotkey, damageTestHotkey

    settings := FileRead("settings.txt")

    ; Parse each line of the settings
    Loop Parse settings, "`n", "`r"
    {
        ; Split the line into setting and value
        if (Trim(A_LoopField) = "")
            continue
        line := StrSplit(A_LoopField, "=")
        setting := Trim(line[1])
        value := line.Has(2) ? Trim(line[2]) : ""

        ; Check each setting and assign the corresponding value
        if (setting == "Reload Script Hotkey")
            reloadScriptHotkey := value
        else if (setting == "Close Script Hotkey")
            closeScriptHotkey := value
        else if (setting == "Settings GUI Hotkey")
            settingsGUIHotkey := value
        else if (setting == "Quick Menu Hotkey")
            quickMenuHotkey := value
        else if (setting == "Damage Test Hotkey")
            damageTestHotkey := value
        else if (setting == "Detect Boss Hotkey")
            detectBossHotkey := value
        else if (setting == "Start And Stop DPS Phase")
            startAndStopDPS := value
        else if (setting == "Manually Start and Stop DPS Phases")
            manualDPSPhases := ParseBooleanValue(value)
        else if (setting == "Include DPS Calculations")
            includeDPSCalculations := ParseBooleanValue(value)
        else if (setting == "DPS Numbers Near Crosshair")
            DPSatCrosshair := ParseBooleanValue(value)
        else if (setting == "Decimal Places in Main Health Percentage")
            decimalPlacesHealthPercentage := value
        else if (setting == "Include Estimated Boss Health")
            includeEstimatedBossHealth := ParseBooleanValue(value)
        else if (setting == "Show Damage Dealt Instead of Boss Health")
            showDamageDealt := ParseBooleanValue(value)
        else if (setting == "Show Damage Phase Duration")
            showDamageDuration := ParseBooleanValue(value)
        else if (setting == "Show Estimated Time to Kill")
            estimateTimeToKill := ParseBooleanValue(value)
        else if (setting == "Include Burst and Sustained Specifiers")
            includeBurstAndSustainedSpecifiers := ParseBooleanValue(value)
        else if (setting == "GUI Text Color")
            textColor := value
        else if (setting == "GUI Text Font")
            textFont := value
        else if (setting == "Display info in a separate window")
            separateWindow := ParseBooleanValue(value)
        else if (setting == "Make Text Bold")
            boldText := ParseBooleanValue(value)
        else if (setting == "1920x1080")
            res1080p := ParseBooleanValue(value)
        else if (setting == "Ultrawide 1440p Monitor")
            isUltraWide := ParseBooleanValue(value)
        else if (setting == "Phase Start Minimum Drop Percent")
            phaseStartMinDrop := value
        else if (setting == "Phase Start Confirm Seconds")
            phaseStartConfirmSeconds := value
        else if (setting == "Phase End After Frozen Seconds")
            phaseEndFrozenSeconds := value
        else if (setting == "Max Instant Drop Percent")
            maxInstantDropPercent := value
        else if (setting == "Big Drop Confirm Seconds")
            bigDropConfirmSeconds := value
        else if (setting == "Show DPS Graph")
            showDPSGraph := ParseBooleanValue(value)
        else if (setting == "Auto Detect Boss")
            autoDetectBoss := ParseBooleanValue(value)
        else if (setting == "Auto Detect Interval Seconds")
            autoDetectIntervalSeconds := value
        else if (setting == "Graph Curves")
        {
            graph_curves := 0
            if !InStr(value, "all")
            {
                if InStr(value, "peak")
                    graph_curves |= 2
                if (InStr(value, "damage") || InStr(value, "dmg"))
                    graph_curves |= 4
                if RegExMatch(value, "i)(^|[^a-z])dps")
                    graph_curves |= 1
            }
            if (!graph_curves)
                graph_curves := 7
        }
        else if (setting == "DPS Interval Seconds")
            dpsWindowSeconds := value
        else if (setting == "CSV Log Hotkey")
            csvLogHotkey := value
        else if (setting == "Copy Phase Summary Hotkey")
            copySummaryHotkey := value
        else if (setting == "Save Phase History")
            savePhaseHistory := ParseBooleanValue(value)
        else if (setting == "Enable Measurement CSV Logger")
            enableCsvLogger := ParseBooleanValue(value)
        else if (setting == "Graph Curves Hotkey")
            graphCurvesHotkey := value
        else if (setting == "Graph Edit Hotkey")
            graphEditHotkey := value
        else if (setting == "Graph Layout")
            graphLayoutOverride := value
        else if (setting == "Healthbar Location")
            healthbarLocationOverride := value
        else if (setting == "Bossname Location")
            bossnameLocationOverride := value
        else if (setting == "Calibrate Hotkey")
            calibrateHotkey := value
        else if (setting == "Encounter Context")
            encounterContext := (value = "epic") ? "epic" : (value = "pantheon") ? "pantheon" : "normal"
        else if (setting == "Encounter Context Hotkey")
            encounterContextHotkey := value
        else if (setting == "Brightness Level")
            brightnessLevel := value
        else if (setting == "Colorblind Setting")
            ColorBlind := value
    }

    brightnessIndex := brightnessLevel - 1
    if (ColorBlind == "Normal" || ColorBlind == "normal")
    {
        hexCodes := ["0xB86708", "0xE49422", "0xBE740D", "0xE69A2A", "0xC88113", "0xE8A032", "0xCC8918", "0xEAA73A", "0xD0901D", "0xECAD42", "0xD39621", "0xFFFFFF"] ; 0xD39621-0xEDB147 default, 0xFFFFFF for full white
        boss_health_colors := findAllColorsBetween(hexCodes[brightnessIndex*2-1], hexCodes[brightnessIndex*2])
    }
    else if (ColorBlind == "Deuteranopia" || ColorBlind == "deuteranopia")
    {
        hexCodes := ["0x606121", "0x929252", "0x6E6A2E", "0x929252", "0x767A37", "0x989958", "0x7E8140", "0x9FA060", "0x868846", "0xA6A768", "0x8E8F4E", "0xAAAB6E"]
        boss_health_colors := findAllColorsBetween(hexCodes[brightnessIndex*2-1], hexCodes[brightnessIndex*2])
    }
    else if (ColorBlind == "Protanopia" || ColorBlind == "protanopia")
    {
        hexCodes := ["0xA76B00", "0xD2A724", "0xAD7700", "0xD4A926", "0xB78500", "0xD8AD2A", "0xBF8A00", "0xDAAF2C", "0xBF9100", "0xDCB12F", "0xC49800", "0xDEB331"]
        boss_health_colors := findAllColorsBetween(hexCodes[brightnessIndex*2-1], hexCodes[brightnessIndex*2])
    }
    else if (ColorBlind == "Tritanopia" || ColorBlind == "tritanopia" )
    {
        hexCodes := ["0x9E414F", "0xCC7F8D", "0xAC525F", "0xCE818E", "0xAF5A67", "0xD08391", "0xB56471", "0xD28694", "0xBA6A77", "0xD58A98", "0xBA727F", "0xD88F9B"]
        boss_health_colors := findAllColorsBetween(hexCodes[brightnessIndex*2-1], hexCodes[brightnessIndex*2])
    }


    ; an invalid hotkey string in settings.txt must not kill startup - skip
    ; the bad one with a warning and keep the rest working
    for pair in [[quickMenuHotkey, toggle_quick_menu],
        [settingsGUIHotkey, ShowSettingsGUI], [startAndStopDPS, manualDPSPhase],
        [damageTestHotkey, damage_test_start],
        [detectBossHotkey, detect_boss], [graphCurvesHotkey, graph_cycle_curves],
        [graphEditHotkey, graph_edit_toggle], [encounterContextHotkey, cycle_encounter_context],
        [csvLogHotkey, toggle_csv_log], [copySummaryHotkey, copy_phase_summary],
        [calibrateHotkey, calibrate_bar],
        [closeScriptHotkey, close_the_script], [reloadScriptHotkey, reload_the_script]]
    {
        if (pair[1] = "")
            continue
        try Hotkey pair[1], pair[2]
        catch
        {
            ToolTip 'Invalid hotkey in settings.txt: "' pair[1] '" - skipped', 100, 100
            SetTimer(clear_tooltip, -4000)
        }
    }
    Return
}

; Helper function to parse boolean values from the settings file
ParseBooleanValue(value) {
    if (value == "true" || value == "1" || value == "True" || value == "TRUE")
        return 1
    else
        return 0
}

; set a bossHealth GUI control if it exists (some controls are only created for certain settings)
gset(name, value) {
    global bossGui
    try bossGui[name].Text := value
}

; tracker state dot: shows exactly one of the three colored overlapping dots
set_tracker_state(state) {
    global bossGui
    for s in ["idle", "locked", "phase"]
        try bossGui["dot_" s].Visible := (s = state)
}

; hide the gui if destiny isnt currently in focus - our own quick menu /
; settings windows count as "in game" so using them doesn't pause tracking
check_destiny_open()
{
    global currently_shown, bossGui, quickGui, settingsGui
    active_ok := WinActive("Destiny 2")
    if (!active_ok && IsObject(quickGui) && WinActive("ahk_id " quickGui.Hwnd))
        active_ok := 1
    if (!active_ok && IsObject(settingsGui) && WinActive("ahk_id " settingsGui.Hwnd))
        active_ok := 1
    if (active_ok)
    {
        if !(currently_shown)
        {
            bossGui.Show("NoActivate")
            currently_shown := 1
        }
    }
    Else
    {
        if (currently_shown)
        {
            bossGui.Hide()
            currently_shown := 0
        }
    }
}

; finds how far the healthbar extends instead of counting every matching pixel
; the bar drains right-to-left, so health is defined by the rightmost filled column;
; glow/buffs bleeding through the translucent middle of the bar can't move that edge
bossHealthPercentage(pBitmap, has_final := 0)
{
    global boss_health_colors, res1080p
    Gdip_GetImageDimensions(pBitmap, &w, &h)
    if (w <= 0 || h <= 0)
        return 0

    ; same trim as the old per-pixel final-stand correction, expressed in columns
    totalCols := w
    loop Integer(has_final)
        totalCols -= res1080p ? 2 : 3
    if (totalCols <= 0)
        return 0

    ; read the pixel buffer directly: one LockBits call replaces a DllCall per
    ; probed pixel (~30k/s at low hp across the tracker + csv logger); the
    ; per-pixel Gdip_GetPixel path stays as a fallback if locking fails
    use_lb := !Gdip_LockBits(pBitmap, 0, 0, w, h, &stride, &scan0, &bmpData, 1)

    ; edge = rightmost column that starts a run of 3 matching columns, so a
    ; stray glint past the real edge can't read as extra health. the bar drains
    ; right-to-left, so scanning from the right and stopping at the first run
    ; means the filled part of the bar is never touched at all
    edge := 0
    run := 0
    m1 := 0, m2 := 0  ; matches at columns 1 and 2 (a lone match there still counts)
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
                edge := x + 3  ; 1-based top of the run
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
    ; contiguity check: a real healthbar extends from its left edge to the
    ; health edge. small warm-white UI elements (the inventory's scroll pill
    ; renders right where the bar lives) pass the color match but only span a
    ; few columns with NOTHING to their left. deliberately loose - only 2 of
    ; 8 probes need a match - because the bar's translucent middle is often
    ; darkened by effects/enemies behind it and must never read as "no bar"
    ; (a strict version here made readings flicker to 0 all fight long). a
    ; ~20px pill scores 0-1: all probes sit at <=85% of the edge, left of it
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

; a healthbar pixel matches if it's in the configured color table, OR if it
; looks like the bar's glow-highlighted state: mechanics (Dredgen Sere,
; Caretaker...) light up a section of the bar, blending its color toward
; white - bright and warm, blue channel clearly below red/green. measured
; from screenshot: normal (203,157,9), glowing (225,201,138)-(247,233,196)
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

; median of three readings; rejects single-frame spikes in either direction
median3(a, b, c)
{
    return a + b + c - Max(a, b, c) - Min(a, b, c)
}

; samples dps during a phase and drives the graph window lifecycle (100ms timer)
graph_tick()
{
    global
    if (!showDPSGraph || !IsObject(graphGui))
        return
    if (edit_mode)
    {
        ; keep the window up and live while the user drags / resizes it
        if (!graph_visible)
        {
            graphGui.Show("NA")
            graph_visible := true
        }
        graph_render()
        return
    }
    if (dps_phase_active && currently_shown)
    {
        if (graph_linger_until)  ; new phase started while the old curve lingered
        {
            graph_samples := []
            graph_linger_until := 0
        }
        ; phase time running backwards means these samples are from a new phase
        if (graph_samples.Length && elapsed_time < graph_samples[graph_samples.Length][1])
            graph_samples := []
        graph_samples.Push([elapsed_time, current_dps, total_damage])
        ; very long phases: thin to every other sample so render cost and
        ; memory stay flat (timestamps keep the curves' shape correct)
        if (graph_samples.Length > 6000)  ; 10 min at 10/s before thinning
        {
            thinned := []
            Loop graph_samples.Length // 2
                thinned.Push(graph_samples[A_Index * 2])
            graph_samples := thinned
        }
        if (!graph_visible)
        {
            graphGui.Show("NA")
            graph_visible := true
        }
        graph_render()
    }
    else if (graph_visible)
    {
        ; phase over: keep the final curve up for a few seconds, redrawn once
        ; so the live dps label flips to the phase's peak summary
        if (!graph_linger_until)
        {
            graph_linger_until := A_TickCount + 4000
            graph_render()
        }
        if (!currently_shown || A_TickCount > graph_linger_until)
        {
            graphGui.Hide()
            graph_visible := false
            graph_samples := []
            graph_linger_until := 0
        }
    }
}

; draws the dps + damage curves with axis marks onto the layered graph window
graph_render()
{
    global
    static in_render := false
    ; never draw while the surface is being rebuilt (wheel resize) or from an
    ; interrupted render - a half-valid graphics pointer crashes inside gdi+
    if (graph_rebuilding || in_render || !graph_G)
        return
    in_render := true
    try
        graph_render_body()
    catch
    {
        ; transient gdi+ hiccup: drop this frame rather than die with a dialog
    }
    in_render := false
}

graph_render_body()
{
    global
    ; dock under the separate window in that mode; otherwise leave the window
    ; where it is (initial Show / user dragging control the position)
    render_x := "", render_y := ""
    if (separateWindow && !edit_mode)
    {
        try
        {
            WinGetPos(&win_x, &win_y, &win_w, &win_h, bossGui.Hwnd)
            render_x := win_x, render_y := win_y + win_h
        }
    }

    Gdip_GraphicsClear(graph_G)
    panelBrush := Gdip_BrushCreateSolid(0xB0141419)
    Gdip_FillRoundedRectangle(graph_G, panelBrush, 0, 0, graph_w, graph_h, 8)
    Gdip_DeleteBrush(panelBrush)

    plot_l := 8, plot_r := graph_w - 8
    plot_t := 18, plot_b := graph_h - 14

    if (graph_samples.Length >= 2)
    {
        ; three series: real-time dps over the trailing dpsWindowSeconds
        ; (orange), its running peak (red), and cumulative damage (blue).
        ; dps and peak share the left scale, damage owns the right one
        n := graph_samples.Length
        t_max := Max(graph_samples[n][1], 1)
        peak_dmg := 0.0001
        for sample in graph_samples
            if (sample[3] > peak_dmg)
                peak_dmg := sample[3]

        inst_series := []
        peak_series := []
        run_peak := 0
        Loop n
        {
            i := A_Index
            j := i
            while (j > 1 && graph_samples[i][1] - graph_samples[j-1][1] < dps_effective_window)
                j -= 1
            ; divide by at least the full window: early samples with only a
            ; sliver of history would otherwise multiply one hp-column step
            ; into a huge fake spike. the window self-widens on sparse
            ; column-stepped damage (see the tracker's adaptive window)
            span := Max(graph_samples[i][1] - graph_samples[j][1], dps_effective_window)
            inst_val := (graph_samples[i][3] - graph_samples[j][3]) / span
            inst_series.Push(inst_val)
            run_peak := Max(run_peak, inst_val)
            peak_series.Push(run_peak)
        }
        scale_dps := Max(run_peak, 0.0001)

        ; y gridlines at quarter heights, value labels color-coded per scale
        gridPen := Gdip_CreatePen(0x28FFFFFF, 1)
        for frac in [0.25, 0.5, 0.75]
        {
            line_y := plot_b - frac * (plot_b - plot_t)
            Gdip_DrawLine(graph_G, gridPen, plot_l, line_y, plot_r, line_y)
            if (graph_curves & 3)
                Gdip_TextToGraphics(graph_G, short_num(scale_dps * frac), "x" (plot_l+2) " y" Round(line_y-11) " Left cbfe8a032 r4 s8 NoWrap", graph_font, graph_w, graph_h)
            if (graph_curves & 4)
                Gdip_TextToGraphics(graph_G, short_num(peak_dmg * frac), "x-" (graph_w-plot_r+2) " y" Round(line_y-11) " Right cbf6fb7ff r4 s8 NoWrap", graph_font, graph_w, graph_h)
        }
        ; x gridlines + second marks at a nice step
        tick := nice_step(t_max, 5)
        t := tick
        while (t < t_max * 0.98)
        {
            px := plot_l + (t / t_max) * (plot_r - plot_l)
            Gdip_DrawLine(graph_G, gridPen, px, plot_t, px, plot_b)
            if (px < plot_r - 34)  ; keep clear of the duration label corner
                Gdip_TextToGraphics(graph_G, Round(t, tick < 1 ? 1 : 0) "s", "x" Round(px-15) " y" (plot_b+1) " w30 Center cbfd8d8d8 r4 s8 NoWrap", graph_font, graph_w, graph_h)
            t += tick
        }
        Gdip_DeletePen(gridPen)

        axisPen := Gdip_CreatePen(0x60FFFFFF, 1)
        Gdip_DrawLine(graph_G, axisPen, plot_l, plot_b, plot_r, plot_b)
        Gdip_DeletePen(axisPen)

        dps_points := ""
        peak_points := ""
        dmg_points := ""
        Loop n
        {
            i := A_Index
            px := Round(plot_l + (graph_samples[i][1] / t_max) * (plot_r - plot_l), 1)
            sep := (i = 1 ? "" : "|")
            dps_points .= sep px "," Round(plot_b - (inst_series[i] / scale_dps) * (plot_b - plot_t), 1)
            peak_points .= sep px "," Round(plot_b - (peak_series[i] / scale_dps) * (plot_b - plot_t), 1)
            dmg_points .= sep px "," Round(plot_b - (graph_samples[i][3] / peak_dmg) * (plot_b - plot_t), 1)
        }

        if (graph_curves & 4)
        {
            dmgPen := Gdip_CreatePen(0xFF6FB7FF, 2)
            Gdip_DrawLines(graph_G, dmgPen, dmg_points)
            Gdip_DeletePen(dmgPen)
        }
        if (graph_curves & 2)
        {
            peakPen := Gdip_CreatePen(0xFFE0564A, 2)
            Gdip_DrawLines(graph_G, peakPen, peak_points)
            Gdip_DeletePen(peakPen)
        }
        if (graph_curves & 1)
        {
            dpsPen := Gdip_CreatePen(0xFFE8A032, 2)
            Gdip_DrawLines(graph_G, dpsPen, dps_points)
            Gdip_DeletePen(dpsPen)
        }

        if (graph_curves & 1)
            Gdip_TextToGraphics(graph_G, "dps " FormatWithCommas(Round(inst_series[n], 0)), "x8 y3 Left cffe8a032 r4 s10 NoWrap", graph_font, graph_w, graph_h)
        if (graph_curves & 2)
            Gdip_TextToGraphics(graph_G, "peak " FormatWithCommas(Round(run_peak, 0)), "x0 y3 Center cffe0564a r4 s10 NoWrap", graph_font, graph_w, graph_h)
        if (graph_curves & 4)
            Gdip_TextToGraphics(graph_G, "dmg " FormatWithCommas(Round(graph_samples[n][3], 0)), "x-8 y3 Right cff6fb7ff r4 s10 NoWrap", graph_font, graph_w, graph_h)
        Gdip_TextToGraphics(graph_G, Round(t_max, 0) "s", "x-6 y" (plot_b+1) " Right cbfd8d8d8 r4 s8 NoWrap", graph_font, graph_w, graph_h)
    }
    else if (edit_mode)
        Gdip_TextToGraphics(graph_G, "graph preview`ndrag to move - mouse wheel to resize`npress the edit hotkey again to save", "x0 y" (graph_h//2 - 22) " w" graph_w " Center cffd8d8d8 r4 s10", graph_font, graph_w, graph_h)

    UpdateLayeredWindow(graphGui.Hwnd, graph_hdc, render_x, render_y, graph_w, graph_h)
}

; largest of 1/2/5 * 10^n giving about `target` ticks over `range`
nice_step(range, target := 4)
{
    if (range <= 0)
        return 1
    raw := range / target
    mag := 10 ** Floor(Log(raw))
    for m in [1, 2, 5, 10]
        if (raw <= m * mag)
            return m * mag
    return 10 * mag
}

short_num(v)
{
    if (v >= 1000000)
        return Round(v / 1000000, 1) "M"
    if (v >= 1000)
        return Round(v / 1000, v >= 100000 ? 0 : 1) "k"
    return Round(v, 0)
}

; ---- quick menu (F2) ----
; an always-available control panel: every toggle and action, wired to the
; same functions as the F-keys, with the key shown so people learn them
toggle_quick_menu(*)
{
    global quickGui
    if (!IsObject(quickGui))
        build_quick_menu()
    if DllCall("IsWindowVisible", "Ptr", quickGui.Hwnd)
        quickGui.Hide()
    else
    {
        quick_menu_sync()
        quickGui.Show("AutoSize")
    }
}

build_quick_menu()
{
    global quickGui
    quickGui := Gui("+AlwaysOnTop -MinimizeBox", "protoDDT menu")
    quickGui.OnEvent("Close", (*) => quickGui.Hide())
    quickGui.OnEvent("Escape", (*) => quickGui.Hide())
    quickGui.SetFont("s10")

    quickGui.SetFont("Bold")
    quickGui.Add("Text", "xm", "Toggles")
    quickGui.SetFont("Norm")
    quickGui.Add("Checkbox", "xm w330 vQMShowGraph", "Show the DPS graph").OnEvent("Click", qm_show_graph)
    quickGui.Add("Checkbox", "xm w330 vQMCurveDps", "Graph curve: real-time dps   [F8 cycles]").OnEvent("Click", qm_curves)
    quickGui.Add("Checkbox", "xm w330 vQMCurvePeak", "Graph curve: peak dps").OnEvent("Click", qm_curves)
    quickGui.Add("Checkbox", "xm w330 vQMCurveDmg", "Graph curve: total damage").OnEvent("Click", qm_curves)
    quickGui.Add("Checkbox", "xm w330 vQMHistory", "Save phase history (csv + png + best records)").OnEvent("Click", qm_history)
    quickGui.Add("Checkbox", "xm w330 vQMLoggerOn", "Allow the measurement logger   [F11]").OnEvent("Click", qm_logger_enable)
    quickGui.Add("Checkbox", "xm w330 vQMManual", "Manual phase mode (start/stop with F3)").OnEvent("Click", qm_manual)
    quickGui.Add("Checkbox", "xm w330 vQMAutoDetect", "Auto boss detection (OCR)").OnEvent("Click", qm_autodetect)

    quickGui.SetFont("Bold")
    quickGui.Add("Text", "xm y+10", "Screen / resolution")
    quickGui.SetFont("Norm")
    quickGui.Add("DropDownList", "xm w190 vQMResolution",
        ["2560x1440 (default)", "1920x1080", "Ultrawide 1440p", "Custom (calibrate now)"]).OnEvent("Change", qm_resolution)
    quickGui.Add("Button", "x+10 w130", "Flush custom").OnEvent("Click", flush_calibration)

    quickGui.SetFont("Bold")
    quickGui.Add("Text", "xm y+10", "Actions")
    quickGui.SetFont("Norm")
    quickGui.Add("Button", "xm w160", "Detect boss now   [F7]").OnEvent("Click", (*) => detect_boss())
    quickGui.Add("Button", "x+10 w160", "Move/resize graph   [F9]").OnEvent("Click", (*) => graph_edit_toggle())
    quickGui.Add("Button", "xm w160", "CSV logger on/off   [F11]").OnEvent("Click", (*) => toggle_csv_log())
    quickGui.Add("Button", "x+10 w160", "Copy phase summary   [F12]").OnEvent("Click", (*) => copy_phase_summary())
    quickGui.Add("Button", "xm w160", "Start/stop phase   [F3]").OnEvent("Click", (*) => manualDPSPhase())
    quickGui.Add("Button", "x+10 w160 vQMContext", "Context: normal   [F10]").OnEvent("Click", qm_context)
    quickGui.Add("Button", "xm w160", "Boss / measure window   [F6]").OnEvent("Click", (*) => ShowSettingsGUI())
    quickGui.Add("Button", "x+10 w160", "Calibrate bar location").OnEvent("Click", (*) => calibrate_bar())
    quickGui.Add("Button", "xm w160", "Reload protoDDT   [F5]").OnEvent("Click", (*) => reload_the_script())
    quickGui.Add("Button", "x+10 w160", "Close protoDDT   [F4]").OnEvent("Click", (*) => close_the_script())
}

; reflect the current state in the checkboxes every time the menu opens
quick_menu_sync()
{
    global
    try
    {
        quickGui["QMShowGraph"].Value := showDPSGraph ? 1 : 0
        quickGui["QMCurveDps"].Value := (graph_curves & 1) ? 1 : 0
        quickGui["QMCurvePeak"].Value := (graph_curves & 2) ? 1 : 0
        quickGui["QMCurveDmg"].Value := (graph_curves & 4) ? 1 : 0
        quickGui["QMHistory"].Value := savePhaseHistory ? 1 : 0
        quickGui["QMLoggerOn"].Value := enableCsvLogger ? 1 : 0
        quickGui["QMManual"].Value := manualDPSPhases ? 1 : 0
        quickGui["QMAutoDetect"].Value := autoDetectBoss ? 1 : 0
        quickGui["QMContext"].Text := "Context: " encounterContext "   [F10]"
        quickGui["QMResolution"].Value := res1080p ? 2 : isUltraWide ? 3
            : (healthbarLocationOverride != "" ? 4 : 1)
    }
}

qm_show_graph(ctrl, *)
{
    global showDPSGraph, graphGui, graph_visible
    showDPSGraph := ctrl.Value
    if (showDPSGraph)
        init_graph()
    else if (IsObject(graphGui))
    {
        try graphGui.Hide()
        graph_visible := false
    }
    save_setting("Show DPS Graph", showDPSGraph ? "true" : "false")
}

qm_curves(ctrl, *)
{
    global graph_curves, quickGui
    v := (quickGui["QMCurveDps"].Value ? 1 : 0)
        | (quickGui["QMCurvePeak"].Value ? 2 : 0)
        | (quickGui["QMCurveDmg"].Value ? 4 : 0)
    if (!v)  ; at least one curve stays on
    {
        v := 1
        quickGui["QMCurveDps"].Value := 1
    }
    graph_curves := v
    save_setting("Graph Curves", (v = 7) ? "all"
        : RTrim(((v & 1) ? "dps+" : "") ((v & 2) ? "peak+" : "") ((v & 4) ? "damage+" : ""), "+"))
}

qm_history(ctrl, *)
{
    global savePhaseHistory
    savePhaseHistory := ctrl.Value
    save_setting("Save Phase History", savePhaseHistory ? "true" : "false")
}

qm_logger_enable(ctrl, *)
{
    global enableCsvLogger
    enableCsvLogger := ctrl.Value
    save_setting("Enable Measurement CSV Logger", enableCsvLogger ? "true" : "false")
}

qm_manual(ctrl, *)
{
    global manualDPSPhases
    manualDPSPhases := ctrl.Value
    save_setting("Manually Start and Stop DPS Phases", manualDPSPhases ? "true" : "false")
}

qm_autodetect(ctrl, *)
{
    global autoDetectBoss, autoDetectIntervalSeconds
    autoDetectBoss := ctrl.Value
    SetTimer(auto_detect_tick, autoDetectBoss ? autoDetectIntervalSeconds * 1000 : 0)
    save_setting("Auto Detect Boss", autoDetectBoss ? "true" : "false")
}

; resolution picker: the base layouts and default regions are resolution-
; dependent, so switching reloads the script; "Custom" runs the calibration
; wizard instead (it overrides the regions on top of whatever base is set)
qm_resolution(ctrl, *)
{
    global
    if (ctrl.Value = 4)
    {
        quickGui.Hide()
        calibrate_bar()
        return
    }
    save_setting("1920x1080", ctrl.Value = 2 ? "true" : "false")
    save_setting("Ultrawide 1440p Monitor", ctrl.Value = 3 ? "true" : "false")
    Reload
}

; failsafe: wipe a mistyped / misclicked custom calibration and fall back to
; the built-in per-resolution regions
flush_calibration(*)
{
    global healthbarLocationOverride, bossnameLocationOverride
    ; settings.txt is the source of truth: also catch values saved by an
    ; earlier session (or edited by hand) that the globals don't know about
    saved_in_file := 0
    try saved_in_file := RegExMatch(FileRead(A_ScriptDir "\settings.txt"), "m)^(Healthbar|Bossname) Location\s*=\s*\S")
    if (!saved_in_file && healthbarLocationOverride = "" && bossnameLocationOverride = "")
    {
        ToolTip "No custom calibration saved - nothing to flush", 100, 100
        SetTimer(clear_tooltip, -2000)
        return
    }
    save_setting("Healthbar Location", "")
    save_setting("Bossname Location", "")
    Reload
}

qm_context(ctrl, *)
{
    global encounterContext
    cycle_encounter_context()
    ctrl.Text := "Context: " encounterContext "   [F10]"
}

; calibration wizard: point at the bar's two ends to teach the tracker any
; resolution - writes the regions to settings.txt and applies them live
calibrate_bar(*)
{
    global healthbar_location, bossname_location, stop_loop
    global healthbarLocationOverride, bossnameLocationOverride
    stop_loop := 1  ; stop any running tracker so the region switch is clean
    CoordMode "Mouse", "Screen"
    ToolTip "Calibration 1/2:`nhover the mouse over the LEFT end of the boss healthbar,`nthen press Space (Esc cancels)", 100, 100
    if !calibrate_wait_key()
    {
        clear_tooltip()
        return
    }
    MouseGetPos &x1, &y1
    ToolTip "Calibration 2/2:`nhover the mouse over the RIGHT end of the boss healthbar,`nthen press Space (Esc cancels)", 100, 100
    if !calibrate_wait_key()
    {
        clear_tooltip()
        return
    }
    MouseGetPos &x2, &y2
    clear_tooltip()
    if (x2 - x1 < 100 || Abs(y2 - y1) > 10)
    {
        MsgBox "Calibration aborted: expected the bar's LEFT then RIGHT end on (almost) the same row, at least 100px apart."
        return
    }
    barw := x2 - x1
    bary := Round((y1 + y2) / 2)
    ; 3 rows around the pointed line; name region uses the same ratios as the
    ; built-in 1080p values (71% of the bar width, starting just under it)
    healthbar_location := x1 "|" (bary - 1) "|" barw "|3"
    bossname_location := x1 "|" (bary + 5) "|" Round(barw * 0.71) "|40"
    save_setting("Healthbar Location", healthbar_location)
    save_setting("Bossname Location", bossname_location)
    ; keep the in-memory overrides in sync, or the resolution menu and the
    ; flush failsafe won't see this calibration until the next reload
    healthbarLocationOverride := healthbar_location
    bossnameLocationOverride := bossname_location
    ToolTip "Calibrated:`nhealthbar " healthbar_location "`nname region " bossname_location "`nsaved to settings.txt", 100, 100
    SetTimer(clear_tooltip, -3500)
}

; wait for space (1) or esc (0) by polling, so both keys can be watched
calibrate_wait_key()
{
    loop
    {
        if GetKeyState("Space", "P")
        {
            KeyWait "Space"
            return 1
        }
        if GetKeyState("Escape", "P")
        {
            KeyWait "Escape"
            return 0
        }
        Sleep 30
    }
}

; copy the last recorded phase's one-line summary (discord-pasteable)
copy_phase_summary(*)
{
    global last_phase_summary
    if (last_phase_summary = "")
        ToolTip "No phase recorded yet", 100, 100
    else
    {
        A_Clipboard := last_phase_summary
        ToolTip "Copied:`n" last_phase_summary, 100, 100
    }
    SetTimer(clear_tooltip, -2500)
}

; cycle which curves are drawn: all -> dps -> peak -> damage -> all
graph_cycle_curves(*)
{
    global graph_curves
    graph_curves := (graph_curves = 7) ? 1 : (graph_curves = 1) ? 2 : (graph_curves = 2) ? 4 : 7
    names := Map(7, "dps + peak + damage", 1, "dps only", 2, "peak only", 4, "damage only")
    ToolTip "Graph: " names[graph_curves], 100, 100
    SetTimer(clear_tooltip, -1500)
}

; ---- csv measurement logger ----
; toggleable: while on, appends a row ONLY when the (median-filtered) health
; reading changes - two spaced shots produce exactly two rows. meant for
; manual damage calculations outside the tracker.
toggle_csv_log(*)
{
    global csv_logging, csv_log_file, csv_log_start, csv_last_hp, csv_base_hp, csv_hist
    global csv_env, csv_candidate, csv_stable
    global csv_hits, csv_hit_sum, csv_first_hit_t, csv_last_hit_t
    global tracking_active, boss_max_hp, enableCsvLogger
    if (!enableCsvLogger)
    {
        ToolTip "Measurement CSV logger is disabled in settings.txt", 100, 100
        SetTimer(clear_tooltip, -2000)
        return
    }
    csv_logging := !IsSet(csv_logging) || !csv_logging
    if (csv_logging)
    {
        ; logs land in the boss's session folder when a boss is tracked
        dir := tracking_active ? session_dir() : A_ScriptDir
        csv_log_file := dir "\dpslog_" A_Year A_Mon A_MDay "-" A_Hour A_Min A_Sec ".csv"
        FileAppend "time_s,hp_percent,damage_percent,hit_percent,damage_hp,hit_hp`r`n", csv_log_file
        csv_log_start := A_TickCount
        csv_last_hp := -1
        csv_base_hp := -1
        csv_hist := []
        csv_env := []
        csv_candidate := -1
        csv_stable := 0
        csv_hits := 0
        csv_hit_sum := 0.0
        csv_first_hit_t := 0
        csv_last_hit_t := 0
        SetTimer(csv_log_tick, 50)
        ToolTip "CSV logging ON`n" csv_log_file, 100, 100
        SetTimer(clear_tooltip, -2500)
    }
    else
    {
        SetTimer(csv_log_tick, 0)
        ; session stats: hits, average hit, hits per minute (needs 2+ hits)
        stats := "CSV logging OFF"
        if (IsSet(csv_hits) && csv_hits > 0)
        {
            avg_hit := csv_hit_sum / csv_hits
            avg_hp := (boss_max_hp > 0) ? Round(avg_hit / 100 * boss_max_hp) : ""
            hpm := (csv_hits >= 2 && csv_last_hit_t > csv_first_hit_t)
                ? Round(csv_hits / ((csv_last_hit_t - csv_first_hit_t) / 60000), 1) : ""
            stats := "hits: " csv_hits ", avg hit: " Round(avg_hit, 3) "%"
                . (avg_hp != "" ? " (" FormatWithCommas(avg_hp) " hp)" : "")
                . (hpm != "" ? ", hits/min: " hpm : "")
            FileAppend "# " stats "`r`n", csv_log_file
            stats := "CSV logging OFF`n" stats
        }
        ToolTip stats, 100, 100
        SetTimer(clear_tooltip, -3500)
    }
}

csv_log_tick()
{
    global csv_log_file, csv_log_start, csv_last_hp, csv_base_hp, csv_hist
    global csv_env, csv_candidate, csv_stable
    global csv_hits, csv_hit_sum, csv_first_hit_t, csv_last_hit_t
    global healthbar_location, boss_max_hp, currently_shown
    ; destiny not focused: the capture would be the desktop, whose pixels can
    ; read as a bar - log nothing and drop stability
    if (!currently_shown)
    {
        csv_hist := []
        csv_env := []
        csv_candidate := -1
        csv_stable := 0
        return
    }
    pBitmap := Gdip_BitmapFromScreen(healthbar_location)
    raw := bossHealthPercentage(pBitmap)
    Gdip_DisposeImage(pBitmap)
    if (raw <= 0)  ; bar not visible (menu/death) - drop stability, log nothing
    {
        csv_hist := []
        csv_env := []
        csv_candidate := -1
        csv_stable := 0
        return
    }
    csv_hist.Push(raw)
    if (csv_hist.Length > 3)
        csv_hist.RemoveAt(1)
    reading := (csv_hist.Length = 3) ? median3(csv_hist[1], csv_hist[2], csv_hist[3]) : raw

    ; boss hp never rises mid-fight, so the max over the last second is the
    ; truth - occlusion/glow dips shorter than that never reach the log
    ; (same envelope trick the main tracker uses)
    csv_env.Push([A_TickCount, reading])
    while (csv_env.Length && A_TickCount - csv_env[1][1] > 1000)
        csv_env.RemoveAt(1)
    for entry in csv_env
        if (entry[2] > reading)
            reading := entry[2]

    ; a row is only written once a value has SETTLED: the same reading (within
    ; 0.02%) for 4 consecutive samples (~200ms). the transition frames while
    ; the bar animates down never settle, so one spaced shot produces exactly
    ; one row instead of a smear of in-between values
    if (csv_candidate >= 0 && Abs(reading - csv_candidate) < 0.02)
        csv_stable += 1
    else
    {
        csv_candidate := reading
        csv_stable := 1
    }
    if (csv_stable < 4)
        return
    if (csv_last_hp >= 0 && Abs(csv_candidate - csv_last_hp) < 0.02)
        return
    if (csv_base_hp < 0)
        csv_base_hp := csv_candidate
    dmg_pct := csv_base_hp - csv_candidate                        ; cumulative since logging started
    hit_pct := (csv_last_hp >= 0) ? csv_last_hp - csv_candidate : 0  ; this row's individual hit
    dmg_hp := (boss_max_hp > 0) ? Round(dmg_pct / 100 * boss_max_hp) : ""
    hit_hp := (boss_max_hp > 0) ? Round(hit_pct / 100 * boss_max_hp) : ""
    t := Round((A_TickCount - csv_log_start) / 1000, 3)
    FileAppend t "," Round(csv_candidate, 4) "," Round(dmg_pct, 4) "," Round(hit_pct, 4) "," dmg_hp "," hit_hp "`r`n", csv_log_file
    if (hit_pct > 0)  ; real hits only (not the baseline row / rebaselines)
    {
        csv_hits += 1
        csv_hit_sum += hit_pct
        if (!csv_first_hit_t)
            csv_first_hit_t := A_TickCount
        csv_last_hit_t := A_TickCount
    }
    csv_last_hp := csv_candidate
}

; edit mode: the graph stops being click-through so it can be dragged around
; and resized with the mouse wheel; toggling off saves the layout to settings
graph_edit_toggle(*)
{
    global
    if (!showDPSGraph || !IsObject(graphGui))
        return
    edit_mode := !edit_mode
    if (edit_mode)
    {
        graphGui.Opt("-E0x20")
        ToolTip "Graph edit mode: drag to move, mouse wheel to resize,`npress the hotkey again to save", 100, 100
        SetTimer(clear_tooltip, -3000)
    }
    else
    {
        graphGui.Opt("+E0x20")
        try
        {
            WinGetPos(&win_x, &win_y, , , graphGui.Hwnd)
            graph_x := win_x, graph_y := win_y
        }
        save_graph_layout()
        ToolTip "Graph layout saved", 100, 100
        SetTimer(clear_tooltip, -1500)
    }
}

; drag support while in edit mode
graph_click(wParam, lParam, msg, hwnd)
{
    global edit_mode, graphGui, graph_x, graph_y
    if (!edit_mode || !IsObject(graphGui) || hwnd != graphGui.Hwnd)
        return
    PostMessage(0xA1, 2, 0, , graphGui)  ; WM_NCLBUTTONDOWN on HTCAPTION
    KeyWait "LButton"
    try
    {
        WinGetPos(&win_x, &win_y, , , graphGui.Hwnd)
        graph_x := win_x, graph_y := win_y
    }
    return 0
}

graph_resize(factor)
{
    global
    if (graph_rebuilding)  ; a queued wheel notch arrived mid-rebuild
        return
    graph_rebuilding := 1
    graph_w := Round(Min(Max(graph_w * factor, 100), 900))  ; same mins as the
    graph_h := Round(Min(Max(graph_h * factor, 60), 500))   ; saved-layout parse
    ; rebuild the drawing surface at the new size
    if (graph_G)
        Gdip_DeleteGraphics(graph_G)
    graph_G := 0
    if (graph_hdc)
    {
        SelectObject(graph_hdc, graph_obm)
        DeleteObject(graph_hbm)
        DeleteDC(graph_hdc)
    }
    graph_hbm := CreateDIBSection(graph_w, graph_h)
    graph_hdc := CreateCompatibleDC()
    graph_obm := SelectObject(graph_hdc, graph_hbm)
    graph_G := Gdip_GraphicsFromHDC(graph_hdc)
    Gdip_SetSmoothingMode(graph_G, 4)
    graph_rebuilding := 0
    graph_render()
}

MouseIsOverGraph()
{
    global graphGui
    if (!IsObject(graphGui))
        return false
    MouseGetPos(, , &hover_win)
    return hover_win = graphGui.Hwnd
}

; write or update a single "Name = value" line in settings.txt in place
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

; persist the layout as "Graph Layout = x|y|w|h" in settings.txt
save_graph_layout()
{
    global graph_x, graph_y, graph_w, graph_h
    save_setting("Graph Layout", Round(graph_x) "|" Round(graph_y) "|" Round(graph_w) "|" Round(graph_h))
}

; per-session output folder: Tracking\<Boss>_<Normal|Epic|Pantheon>_<date>
; holds that boss's phases.csv, graph PNGs and F11 measurement logs
session_dir()
{
    global current_boss, boss_variant
    v := boss_variant.Get(current_boss, "normal")
    variant := (v = "pantheon") ? "Pantheon" : (v = "epic") ? "Epic" : "Normal"
    name := RegExReplace(current_boss, " \[(Pantheon|Epic)\]$", "")
    name := RegExReplace(name, '[\\/:*?"<>|,]', "")
    name := Trim(RegExReplace(name, "\s+", " "))
    if (name = "")
        name := "NoBoss"
    dir := A_ScriptDir "\Tracking\" name "_" variant "_" A_YYYY "-" A_MM "-" A_DD
    if !DirExist(dir)
        DirCreate dir
    return dir
}

; highest damage done in any trailing window of `w` seconds, as dps
best_burst(w)
{
    global burst_hist
    best := 0.0
    i := 1
    for j, e in burst_hist
    {
        while (e[1] - burst_hist[i][1] > w * 1000)
            i += 1
        best := Max(best, e[2] - burst_hist[i][2])
    }
    return best / w
}

; snapshot the graph surface (already holding the final curve) into a png
save_graph_png(path)
{
    global showDPSGraph, graph_samples, graph_hdc, graph_hbm, graph_obm
    if (!showDPSGraph || graph_samples.Length < 2 || !graph_hdc)
        return
    graph_render()  ; make sure the surface is current
    prev := SelectObject(graph_hdc, graph_obm)  ; deselect our DIB so gdi+ can copy it
    pBmp := Gdip_CreateBitmapFromHBITMAP(graph_hbm)
    SelectObject(graph_hdc, prev)
    if (pBmp)
    {
        Gdip_SaveBitmapToFile(pBmp, path)
        Gdip_DisposeImage(pBmp)
    }
}

; persist the best phase per boss across all sessions; returns 1 when this
; phase beat an existing record (0 for first records / no improvement)
update_best_record()
{
    global current_boss, total_damage, current_dps, phase_peak_dps, elapsed_time
    path := A_ScriptDir "\Tracking\best_records.csv"
    if !DirExist(A_ScriptDir "\Tracking")
        DirCreate A_ScriptDir "\Tracking"
    key := StrReplace(current_boss, ",", ";")
    rows := Map()
    if FileExist(path)
    {
        Loop Read path
        {
            if (A_Index = 1)
                continue
            parts := StrSplit(A_LoopReadLine, ",")
            if (parts.Length >= 2)
                rows[parts[1]] := A_LoopReadLine
        }
    }
    prev_dmg := 0
    if rows.Has(key)
        prev_dmg := StrSplit(rows[key], ",")[2] + 0
    if (total_damage <= prev_dmg)
        return 0
    rows[key] := key "," Round(total_damage) "," current_dps "," Round(phase_peak_dps) "," elapsed_time "," A_YYYY "-" A_MM "-" A_DD
    out := "boss,damage,avg_dps,peak_dps,duration_s,date`r`n"
    for , line in rows
        out .= line "`r`n"
    f := FileOpen(path, "w")
    f.Write(out)
    f.Close()
    return prev_dmg > 0

}

; end the current dps phase and reset totals + gui fields.
; dump_graph also clears the graph immediately (artifact / reset dumps)
; instead of letting the final curve linger - dumped phases are never
; recorded to the history either
end_dps_phase(dump_graph := false)
{
    global dps_phase_active, total_damage, highest_dps, dps_start_time
    global includeDPSCalculations, showDamageDuration, estimateTimeToKill
    global includeBurstAndSustainedSpecifiers, DPSatCrosshair
    global graph_samples, graph_linger_until, graph_visible, graphGui
    global current_boss, current_dps, elapsed_time, boss_max_hp
    global phase_peak_dps, phase_hp_start, phase_hp_end, phase_killed, phase_ttfd
    global burst_hist, last_phase_summary, savePhaseHistory
    ; phase history: one row per naturally ended phase with real damage,
    ; written into the boss's session folder along with the graph png
    if (dps_phase_active && !dump_graph && total_damage > 0 && elapsed_time >= 1)
    {
        b3 := Round(best_burst(3))
        b5 := Round(best_burst(5))
        b10 := Round(best_burst(10))
        phases_left := (!phase_killed && total_damage > 0 && boss_max_hp > 0)
            ? Round(phase_hp_end / 100 * boss_max_hp / total_damage, 1) : 0
        attempt := 0
        beat_record := 0
        ; file outputs (row + png + best records) only when the user wants them;
        ; the F12 clipboard summary works either way
        if (savePhaseHistory)
        {
            dir := session_dir()
            csv_path := dir "\phases.csv"
            attempt := 1
            if FileExist(csv_path)
            {
                Loop Read csv_path
                    attempt := A_Index  ; header counts as the +1
            }
            if !FileExist(csv_path)
                FileAppend "date,time,boss,attempt,duration_s,damage,avg_dps,peak_dps,best3s_dps,best5s_dps,best10s_dps,ttfd_s,hp_start,hp_end,killed,phases_left`r`n", csv_path
            boss_field := StrReplace(current_boss, ",", ";")  ; keep the csv well-formed
            FileAppend A_YYYY "-" A_MM "-" A_DD "," A_Hour ":" A_Min ":" A_Sec ","
                . boss_field "," attempt "," elapsed_time "," Round(total_damage) "," current_dps ","
                . Round(phase_peak_dps) "," b3 "," b5 "," b10 "," phase_ttfd ","
                . Round(phase_hp_start, 2) "," Round(phase_hp_end, 2) ","
                . phase_killed "," phases_left "`r`n", csv_path
            save_graph_png(dir "\phase_" attempt "_" A_Hour "-" A_Min "-" A_Sec ".png")
            ; full-resolution time series, ~10 rows/s: sampled by the tracker
            ; loop itself (burst_hist), so it exists even with the graph off.
            ; dps_1s is the trailing-1s dps, matching the graph's dps curve
            if (burst_hist.Length >= 2)
            {
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
                FileAppend ts, dir "\phase_" attempt "_" A_Hour "-" A_Min "-" A_Sec "_data.csv"
            }
            beat_record := update_best_record()
        }
        last_phase_summary := current_boss (attempt ? " #" attempt : "") " - " elapsed_time "s, "
            . FormatWithCommas(Round(total_damage)) " dmg, "
            . FormatWithCommas(current_dps) " avg dps, "
            . FormatWithCommas(Round(phase_peak_dps)) " peak dps ("
            . Round(phase_hp_start, 1) "% -> " Round(phase_hp_end, 1) "%)"
            . " | best 5s: " FormatWithCommas(b5) " dps"
            . (phase_killed ? " | KILL" : phases_left ? " | ~" phases_left " phases left" : "")
            . (beat_record ? " | NEW BEST" : "")
        if (beat_record)
        {
            ToolTip "NEW BEST PHASE for " current_boss "!`n" last_phase_summary, 100, 100
            SetTimer(clear_tooltip, -3500)
        }
    }
    phase_killed := 0
    dps_phase_active := false
    total_damage := 0
    highest_dps := 0
    if (dump_graph)
    {
        graph_samples := []
        graph_linger_until := 0
        if (graph_visible && IsObject(graphGui))
        {
            try graphGui.Hide()
            graph_visible := false
        }
    }
    if (includeDPSCalculations && (includeBurstAndSustainedSpecifiers || DPSatCrosshair))
    {
        gset("HighestDPS", 0)
        gset("AverageDPS", 0)
    }
    if (showDamageDuration)
        gset("DPSDuration", 0)
    if (estimateTimeToKill)
        gset("TimeToKill", 0)
    set_tracker_state("locked")  ; still tracking the boss, just no phase
}

; functions for getting every possible color the bosses healthbar could be
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
                    ; store colors as integer ARGB keys so they match Gdip_GetPixel's return value
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
; =============================

; this is the main driving fucntion in this script
calculateDPS(bossName)
{
    global dps_start_time, last_boss_hp_percent, time_of_last_damage, boss_max_hp
    global total_damage := 0
    global highest_dps := 0
    global stop_loop, change_phase, dps_phase_active, elapsed_time, time_to_kill, percent_dealt, current_dps
    global boss_health_pool, boss_final_stand, healthbar_location, currently_shown
    global manualDPSPhases, showDamageDealt, showDamageDuration, estimateTimeToKill
    global includeDPSCalculations, includeEstimatedBossHealth, decimalPlacesHealthPercentage
    global includeBurstAndSustainedSpecifiers, DPSatCrosshair
    global tracking_active, current_boss, switch_to_boss
    global dpsWindowSeconds, dps_effective_window, phase_peak_dps, phase_hp_start, phase_hp_end, phase_killed
    global phase_ttfd, burst_hist, graph_samples, showDPSGraph

    tracking_active := true
    current_boss := bossName
    switch_to_boss := ""
    stop_loop := 0
    set_tracker_state("locked")
    last_boss_hp_percent := -1
    last_fast_hp := -1  ; previous pre-envelope (median-only) reading
    time_of_last_damage := A_TickCount
    current_dps := 0
    hp_hist := []  ; last few raw readings, median-filtered to reject one-frame flashes
    env_hist := []  ; [tick, reading] pairs for the envelope filter below
    env_window_ms := 1200  ; boss hp never rises mid-fight, so the max reading over this
                           ; window is the truth; occlusion dips shorter than it vanish
    bar_hidden := false
    unhide_warmup := 0  ; ticks to skip after the bar returns (partial renders)
    last_good_hp := -1  ; last reading where the bar was actually visible
    pending_baseline := -1  ; hp before a not-yet-confirmed drop (sustained phase start)
    pending_drop_tick := 0
    hidden_since := 0       ; when the bar disappeared (menu opened)
    last_unhide_tick := 0   ; when the bar last came back
    last_hidden_ms := 0     ; how long that last blackout was
    quarantine_active := false
    quarantine_since := 0
    quarantine_low := 0     ; lowest reading seen while quarantined
    phase_start_baseline := 999  ; hp when the current auto phase started (999 = not tracked)
    phase_min_hp := 999          ; lowest believed hp this phase; damage only counts below it
    phase_total_baseline := 999  ; hp the phase's damage total is measured from
    peak_hist := []              ; [tick, total] pairs for the rolling peak-dps window
    last_damage_event_tick := 0  ; when damage last actually counted
    damage_gap_s := 0            ; smoothed spacing between damage events
    bar_seen_tick := A_TickCount ; when the bar (re)appeared - start of the ttfd clock

    boss_max_hp := boss_health_pool.Get(bossName, 0)
    final_stand := boss_final_stand.Get(bossName, 0)

    If (bossName == "default with final stand" || bossName == "default")
        is_default := 1
    Else
        is_default := 0

    if (showDamageDuration)
        SetTimer(show_damage_duration, 50)
    if (estimateTimeToKill)
        SetTimer(calculate_kill_time, 100)

    Loop
    {
        ; checked outside the focus gate: a stop requested while destiny is
        ; unfocused must still end this loop, or a second tracker could be
        ; started alongside it (two loops corrupt the shared globals)
        if (stop_loop)
            Break
        if (currently_shown)
        {
            ; detection asked us to track a different boss: retarget in place
            if (switch_to_boss != "")
            {
                newBoss := switch_to_boss
                switch_to_boss := ""
                if (newBoss != bossName)
                {
                    bossName := newBoss
                    current_boss := bossName
                    boss_max_hp := boss_health_pool.Get(bossName, 0)
                    final_stand := boss_final_stand.Get(bossName, 0)
                    is_default := (bossName == "default with final stand" || bossName == "default") ? 1 : 0
                    end_dps_phase()
                    current_dps := 0
                    last_boss_hp_percent := -1
                    last_fast_hp := -1
                    last_good_hp := -1
                    bar_hidden := false
                    pending_baseline := -1
                    phase_start_baseline := 999
                    phase_min_hp := 999
                    phase_total_baseline := 999
                    quarantine_active := false
                    hp_hist := []
                    env_hist := []
                    bar_seen_tick := A_TickCount
                    ToolTip "Now tracking: " bossName, 100, 100
                    SetTimer(clear_tooltip, -1500)
                }
            }

            ; take a screenshot and find the boss health percentage
            pBitmap := Gdip_BitmapFromScreen(healthbar_location)
            raw_hp := bossHealthPercentage(pBitmap, final_stand)

            ; inventory/menu handling: the bar vanishing entirely while the boss still
            ; had health means it's hidden, not dead - hold the last reading and keep
            ; the phase timer alive; when the bar returns, flush the filters so the
            ; reading jumps straight to whatever damage teammates did meanwhile
            ; kill vs menu: the bar vanishing moments after damage with the
            ; boss nearly dead is a kill - count the final sliver to zero and
            ; close the phase out. mega-burns can empty the whole bar in 1-2s;
            ; without this the death would either be held as a "hidden" bar or
            ; leave the phase running until the frozen timeout
            ; the low reading must be ESTABLISHED: fresh out of a quarantine
            ; accept / menu return it could be a false bar, not a death
            if (raw_hp <= 0 && dps_phase_active && !bar_hidden
                && last_good_hp > 0 && last_good_hp <= 10
                && (A_TickCount - last_unhide_tick) > 1500
                && (A_TickCount - time_of_last_damage) < 1500)
            {
                kill_baseline := (phase_total_baseline <= 500) ? phase_total_baseline : last_good_hp
                total_damage := Max(kill_baseline * boss_max_hp / 100, total_damage)
                elapsed_time := Round((A_TickCount - dps_start_time) / 1000, 2)
                if (elapsed_time > 0)
                    current_dps := Round(total_damage / elapsed_time, is_default ? 3 : 0)
                highest_dps := Max(highest_dps, current_dps)
                gset("PercentHealth", Round(0, decimalPlacesHealthPercentage) "%")
                if (showDPSGraph)
                    graph_samples.Push([elapsed_time, current_dps, total_damage])
                phase_killed := 1
                phase_hp_end := 0
                end_dps_phase()  ; graph lingers with the final curve; records the phase
                bar_seen_tick := A_TickCount
                last_good_hp := -1
                last_boss_hp_percent := -1
                last_fast_hp := -1
                bar_hidden := false
                pending_baseline := -1
                phase_start_baseline := 999
                phase_min_hp := 999
                phase_total_baseline := 999
                hp_hist := []
                env_hist := []
                Gdip_DisposeImage(pBitmap)
                Sleep 30
                continue
            }
            if (raw_hp <= 0 && last_good_hp > 3)
            {
                if (!bar_hidden)
                    hidden_since := A_TickCount
                bar_hidden := true
                raw_hp := last_good_hp
                if (dps_phase_active)
                {
                    ; a short blackout is a menu - keep the phase alive. but a
                    ; bar gone longer than the frozen timeout means the activity
                    ; ended, so the 8s rule applies to hidden bars too
                    if ((A_TickCount - hidden_since) < phaseEndFrozenSeconds * 1000)
                        time_of_last_damage := A_TickCount
                    else
                        end_dps_phase()
                }
            }
            else
            {
                if (bar_hidden && raw_hp > 0)
                {
                    bar_hidden := false
                    last_unhide_tick := A_TickCount
                    last_hidden_ms := A_TickCount - hidden_since
                    hp_hist := []
                    env_hist := []
                    ; the first frames after a menu closes can catch the bar
                    ; mid-render (partially filled) - refill the median window
                    ; before trusting any reading, or a single bad frame
                    ; becomes phantom mega-damage
                    unhide_warmup := 2
                }
                ; quarantined readings are suspect - keeping them out of
                ; last_good_hp stops a false menu bar from sneaking in through
                ; the hidden-bar hold when the bar flickers under parallax
                if (raw_hp > 0 && !quarantine_active)
                    last_good_hp := raw_hp
            }

            hp_hist.Push(raw_hp)
            if (hp_hist.Length > 3)
                hp_hist.RemoveAt(1)
            boss_hp_percent := (hp_hist.Length = 3) ? median3(hp_hist[1], hp_hist[2], hp_hist[3]) : raw_hp

            ; still warming up after the bar returned: collect samples for the
            ; median window but act on nothing
            if (unhide_warmup > 0)
            {
                unhide_warmup -= 1
                Gdip_DisposeImage(pBitmap)
                Sleep 30
                continue
            }

            ; pre-envelope reading for phase-START detection only: the envelope
            ; below holds the max of the last 1.2s, which used to add its full
            ; window to the time before a phase (and its graph) could begin.
            ; the pending-drop confirm logic has its own noise rejection, so it
            ; can safely watch the faster median-only value
            fast_hp := boss_hp_percent

            ; envelope filter: report the max reading of the last env_window_ms, so dips
            ; from things glowing/moving behind the translucent bar never count as damage
            env_hist.Push([A_TickCount, boss_hp_percent])
            while (env_hist.Length && A_TickCount - env_hist[1][1] > env_window_ms)
                env_hist.RemoveAt(1)
            for entry in env_hist
                if (entry[2] > boss_hp_percent)
                    boss_hp_percent := entry[2]

            ; quarantine implausible collapses: immune dims and glowing damage
            ; sections (Caretaker) can wipe out a chunk of matching columns at
            ; once, but real damage never removes more than a few percent in one
            ; tick. hold the previous value; if the reading bounces back it
            ; never happened, if it persists it's real (one-shot mechanic) and
            ; gets timed like a hidden-bar catch-up so dps stays sane
            if (last_boss_hp_percent >= 0 && !bar_hidden)
            {
                ; a collapse in the first moment after the bar came back from a
                ; menu is the expected teammate catch-up, not an artifact -
                ; accept it instantly instead of quarantining it for 1.5s
                if ((last_boss_hp_percent - boss_hp_percent) > maxInstantDropPercent
                    && ((last_boss_hp_percent - boss_hp_percent) > 40
                     || (A_TickCount - last_unhide_tick) > 800))
                {
                    if (!quarantine_active)
                    {
                        quarantine_active := true
                        quarantine_since := A_TickCount
                        quarantine_low := boss_hp_percent
                        ; a >40% cliff is likely a menu's false bar; it already
                        ; slipped into last_good_hp this tick - roll that back
                        ; so the hidden-bar hold can't resurrect the bogus value
                        ; when the false bar flickers under cursor parallax
                        if ((last_boss_hp_percent - boss_hp_percent) > 40)
                            last_good_hp := last_boss_hp_percent
                    }
                    ; a mega-burn keeps carving new lows tick after tick, while
                    ; an artifact (immune dim, glow) collapses once and holds
                    ; flat - readings that keep sinking are real damage and get
                    ; accepted right away instead of after the 1.5s hold
                    keeps_sinking := boss_hp_percent < quarantine_low - 0.5
                    quarantine_low := Min(quarantine_low, boss_hp_percent)
                    if (!keeps_sinking && A_TickCount - quarantine_since < bigDropConfirmSeconds * 1000)
                        boss_hp_percent := last_boss_hp_percent  ; hold
                    else if (!keeps_sinking && ocr_detect_name() = "")
                    {
                        ; a flat collapse of ANY size with no boss name on
                        ; screen is a menu, not damage: character-screen UI
                        ; (gold icon borders under parallax) can read as a
                        ; false bar anywhere from a sliver to half full, and
                        ; accepting one used to spike the phase by millions.
                        ; keep holding the real value and re-check every 2s -
                        ; when the menu closes the name comes back and any
                        ; teammate catch-up damage is accepted then. real
                        ; one-shot mechanics keep their name on screen, so
                        ; they still get accepted after the confirm window
                        quarantine_since := A_TickCount + 2000 - bigDropConfirmSeconds * 1000
                        boss_hp_percent := last_boss_hp_percent
                    }
                    else
                    {
                        quarantine_active := false
                        hidden_since := quarantine_since
                        last_unhide_tick := A_TickCount
                        ; an accepted hold released this much compressed damage
                        last_hidden_ms := Max(A_TickCount - quarantine_since, 0)
                    }
                }
                else
                    quarantine_active := false
            }
            ; the hold must survive hidden ticks too: a false menu bar
            ; flickering under parallax alternates visible/hidden, and the
            ; collapsed reading would otherwise slip through on hidden ticks
            else if (bar_hidden && quarantine_active)
                boss_hp_percent := last_boss_hp_percent

            percent_dealt := 1 - (boss_hp_percent/100) ; temporary to help find boss actual health pools

            ; calculate the total boss hp left or dealt depending on user preference
            if (showDamageDealt)
                boss_total_health := FormatWithCommas(Round((1-(boss_hp_percent/100))*boss_max_hp, 0))
            Else
                boss_total_health := FormatWithCommas(Round((boss_hp_percent/100)*boss_max_hp, 0))

            ; auto phase start: the drop has to be big enough and persist long enough
            ; that one or two noisy pixels can't trigger a phase. watches the
            ; pre-envelope fast_hp so the phase (and graph) starts ~1s sooner;
            ; a phantom start from a short occlusion dip recovers and dumps
            ; itself via the full-recovery check further down
            if (!dps_phase_active && !manualDPSPhases && last_fast_hp >= 0
                && !bar_hidden && !quarantine_active)
            {
                ; the 0.001 tolerance matters: median3/envelope arithmetic
                ; wobbles by ~1e-13 when the filter window's composition
                ; changes, and a bare > read that as "rising" and cancelled
                ; pending trickle drops right before they could confirm
                if (fast_hp > last_fast_hp + 0.001)
                    pending_baseline := -1  ; bar is rising (spawn/respawn fill) - damage never raises it
                else if (pending_baseline < 0 && fast_hp < last_fast_hp)
                {
                    pending_baseline := last_fast_hp
                    pending_drop_tick := A_TickCount
                }
                else if (pending_baseline >= 0 && fast_hp >= pending_baseline)
                    pending_baseline := -1  ; recovered, it was noise

                ; ANY believable drop (>= 0.05%, under half a bar column) that
                ; survives the confirm window starts the phase. high-HP bosses
                ; shed bar columns slowly, so nearly every start there is a
                ; single-column "trickle" - the old 3x confirm window for
                ; small drops added a flat second before the graph could
                ; begin. noise dips recover and cancel pending within the
                ; window; the rare one that persists starts a phase that
                ; self-dumps on full recovery. phaseStartMinDrop still lowers
                ; the threshold further if a user sets it under 0.05
                pending_drop := (pending_baseline >= 0) ? pending_baseline - fast_hp : 0
                pending_held := A_TickCount - pending_drop_tick
                pending_confirmed := pending_baseline >= 0
                    && pending_drop >= Min(phaseStartMinDrop, 0.05)
                    && pending_held >= phaseStartConfirmSeconds * 1000
                ; a confirmed collapse bigger than any real tick of damage
                ; with NO boss name on screen is a menu's false bar sneaking
                ; past the envelope (the fast reading sees it 1.2s before the
                ; quarantine can) - don't start a phase on it; restart the
                ; confirm window so the ocr re-checks in another 0.5s.
                ; mega-burns keep their name on screen, so they pass
                if (pending_confirmed && pending_drop > maxInstantDropPercent && ocr_detect_name() = "")
                {
                    pending_confirmed := false
                    pending_drop_tick := A_TickCount
                }
                if (pending_confirmed)
                {
                    ; confirmed: backdate the timer to when the drop was first seen and
                    ; seed the damage dealt up to the previous tick (this tick's delta
                    ; is added by the normal accumulation below)
                    dps_phase_active := true
                    dps_start_time := pending_drop_tick
                    ; a drop right after the bar came back from a menu (or out of
                    ; quarantine) is damage spread across that whole stretch -
                    ; time it accordingly or the dps / time to kill / peak explode
                    if (hidden_since && last_unhide_tick && (pending_drop_tick - last_unhide_tick) < 1000)
                        dps_start_time := hidden_since
                    elapsed_time := 0  ; so the graph sampler can't grab the old phase's clock
                    time_of_last_damage := A_TickCount
                    ; the total is recomputed from this baseline every tick, so
                    ; no explicit seed (and no double count)
                    total_damage := 0
                    ; seed the phase minimum from the fast reading so the
                    ; confirmed drop shows as damage IMMEDIATELY instead of
                    ; after the 1.2s envelope catches up (the graph appeared
                    ; with empty values otherwise). capped 2% under the
                    ; baseline: the enveloped reading still sits at the
                    ; baseline, and a gap > 2% would trip the rise-rollback
                    phase_min_hp := Max(fast_hp, pending_baseline - 2)
                    phase_total_baseline := pending_baseline
                    phase_start_baseline := pending_baseline
                    phase_peak_dps := 0
                    phase_killed := 0
                    peak_hist := []
                    burst_hist := []
                    last_damage_event_tick := 0
                    damage_gap_s := 0
                    dps_effective_window := Max(dpsWindowSeconds, 0.2)
                    phase_ttfd := Round(Max(dps_start_time - bar_seen_tick, 0) / 1000, 1)
                    pending_baseline := -1
                    set_tracker_state("phase")
                }
            }
            ; manual phase start stays immediate (baseline check disabled for it)
            if (change_phase && !dps_phase_active)
            {
                change_phase := 0
                dps_phase_active := true
                dps_start_time := A_TickCount
                elapsed_time := 0
                time_of_last_damage := A_TickCount
                pending_baseline := -1
                phase_start_baseline := 999
                phase_min_hp := 999          ; both anchor to the current reading
                phase_total_baseline := 999  ; on the first dps tick
                phase_peak_dps := 0
                phase_killed := 0
                peak_hist := []
                burst_hist := []
                last_damage_event_tick := 0
                damage_gap_s := 0
                dps_effective_window := Max(dpsWindowSeconds, 0.2)
                phase_ttfd := Round(Max(A_TickCount - bar_seen_tick, 0) / 1000, 1)
                set_tracker_state("phase")
            }

            ; if the damage phase is active then calculate dps and related variables
            if (dps_phase_active)
            {
                ; damage is derived straight from the bar every tick: baseline
                ; minus the lowest believed hp. small rises (glow wobble) leave
                ; the minimum alone; a rise bigger than 2% is impossible for
                ; real hp, so the earlier collapse was a misread and the
                ; minimum rolls back - phantom damage un-counts itself instead
                ; of sticking to the phase as a multi-million lump
                ; sentinel is 999; test against 500 because a real baseline can
                ; sit an epsilon above 100 from the median float arithmetic
                if (phase_min_hp > 500)
                {
                    phase_min_hp := boss_hp_percent  ; manual phase: anchor here
                    if (phase_total_baseline > 500)
                        phase_total_baseline := boss_hp_percent
                }
                if (boss_hp_percent < phase_min_hp || boss_hp_percent > phase_min_hp + 2)
                    phase_min_hp := boss_hp_percent
                damage_before := total_damage
                total_damage := Max((phase_total_baseline - phase_min_hp) * boss_max_hp / 100, 0)

                ; only COUNTED damage keeps the phase alive - a glow wobbling
                ; the reading up and down must not defer the frozen timeout
                if (total_damage > damage_before)
                {
                    time_of_last_damage := A_TickCount
                    ; adaptive dps window: measure how sparse the damage
                    ; events actually are. real dps counts damage every tick
                    ; (window stays at dpsWindowSeconds); a trickle weapon on
                    ; a high-hp boss sheds whole bar columns seconds apart,
                    ; and a 1s window on 2s-spaced steps reads 2x the real
                    ; dps whenever two steps land close together. widening
                    ; the window to ~1.5 gaps makes peak/graph dps honest
                    if (last_damage_event_tick)
                    {
                        gap := (A_TickCount - last_damage_event_tick) / 1000.0
                        damage_gap_s := damage_gap_s ? 0.7 * damage_gap_s + 0.3 * gap : gap
                    }
                    last_damage_event_tick := A_TickCount
                    dps_effective_window := Max(dpsWindowSeconds, Min(damage_gap_s * 1.5, 5))
                    ; damage landing right after the bar returned from a menu
                    ; is the hidden stretch's catch-up lump (teammates kept
                    ; shooting) - restart the burst/peak windows and the graph
                    ; so a 15s lump can't read as a one-second burst of
                    ; millions and poison the peak for the rest of the phase.
                    ; ONLY after a real blackout (> 2s): sub-second occlusion
                    ; flickers also pass through the hidden/unhide machinery,
                    ; and wiping the windows on every flicker starved the
                    ; graph of samples under normal trickle damage
                    if (last_unhide_tick && last_hidden_ms > 2000
                        && A_TickCount - last_unhide_tick < 1500)
                    {
                        peak_hist := []
                        burst_hist := []
                        graph_samples := []
                    }
                }

                ; phase-record fields: rolling peak dps over dpsWindowSeconds
                ; (graph-independent), and the hp span for the history row
                peak_hist.Push([A_TickCount, total_damage])
                while (peak_hist.Length && A_TickCount - peak_hist[1][1] > dps_effective_window * 1000)
                    peak_hist.RemoveAt(1)
                peak_span := (A_TickCount - peak_hist[1][1]) / 1000
                phase_peak_dps := Max(phase_peak_dps, (total_damage - peak_hist[1][2]) / Max(peak_span, dps_effective_window))
                phase_hp_start := phase_total_baseline
                phase_hp_end := boss_hp_percent
                ; burst-window samples for the 3s/5s/10s stats, ~10 per second
                if (!burst_hist.Length || A_TickCount - burst_hist[burst_hist.Length][1] >= 100)
                    burst_hist.Push([A_TickCount, total_damage])

                ; update the elapsed time
                elapsed_time := Round((A_TickCount - dps_start_time) / 1000, 2)  ; Convert from ms to s

                ; calculate the average dps and adjust highest dps if its changed
                ; burst (highest running average) only counts once the average
                ; has >= 2s of history: with the instant damage seed, a single
                ; bar column over a fraction of a second read as a fake
                ; "burst" of 2-3x the real dps on trickle weapons (one column
                ; is 2,366 hp on a 1.5M boss at 1080p - the early average is
                ; pure quantization noise)
                if (is_default)
                {
                    current_dps := elapsed_time > 0 ? Round((total_damage / elapsed_time), 3) : 0
                    if (elapsed_time >= 2)
                        highest_dps :=  Round((max(highest_dps, current_dps)), 3)
                }
                Else
                {
                    current_dps := elapsed_time > 0 ? Round((total_damage / elapsed_time), 0) : 0
                    if (elapsed_time >= 2)
                        highest_dps :=  Round((max(highest_dps, current_dps)), 0)
                }

                ; calculate the time to kill the boss based on the current dps and the hp left
                time_to_kill := current_dps > 0 ? Round((boss_max_hp*(boss_hp_percent/100))/current_dps, 2) : 0
            }

            ; a rise back to full while a phase is running means a wipe or encounter
            ; reset - dump the phase data (rises pass the envelope instantly)
            if (dps_phase_active && boss_hp_percent >= 99.5 && boss_hp_percent > last_boss_hp_percent && last_boss_hp_percent >= 0)
            {
                end_dps_phase(true)
                pending_baseline := -1
                phase_start_baseline := 999
                bar_seen_tick := A_TickCount  ; respawn: restart the ttfd clock
            }

            ; an auto phase whose "damage" fully recovers to the starting hp was
            ; a visual artifact (immune dim, glowing bar section) - dump it and
            ; the graph with it. MUST compare the fast (pre-envelope) reading:
            ; phases now start before the envelope has caught up, so for up to
            ; 1.2s the enveloped value still sits at the baseline and would
            ; instantly dump every freshly started phase
            if (dps_phase_active && phase_start_baseline <= 500 && fast_hp >= phase_start_baseline - 0.01)
            {
                end_dps_phase(true)
                pending_baseline := -1
                phase_start_baseline := 999
            }

            ; if the bar has been frozen for too long end the dps phase
            if (((A_TickCount - time_of_last_damage) >= phaseEndFrozenSeconds * 1000 && !manualDPSPhases) || (change_phase && dps_phase_active))
            {
                change_phase := 0
                end_dps_phase()
            }

            ; update the gui
            if (last_boss_hp_percent != boss_hp_percent)
            {
                gset("PercentHealth", Round(boss_hp_percent, decimalPlacesHealthPercentage) "%")
                if (includeEstimatedBossHealth && !(is_default))
                    gset("TotalHealth", boss_total_health " / " FormatWithCommas(boss_max_hp))
            }

            if (dps_phase_active)
            {
                ; specifiers off hides the burst/sustained numbers too (the
                ; crosshair mode has no labels, so it keeps its numbers)
                if (includeDPSCalculations && (includeBurstAndSustainedSpecifiers || DPSatCrosshair))
                {
                    if (is_default)
                    {
                        gset("AverageDPS", FormatWithCommas(current_dps) "%")
                        gset("HighestDPS", FormatWithCommas(highest_dps) "%")
                    }
                    Else
                    {
                        gset("AverageDPS", FormatWithCommas(current_dps))
                        gset("HighestDPS", FormatWithCommas(highest_dps))
                    }
                }

                if (showDamageDuration)
                    gset("DPSDuration", elapsed_time)
                if (estimateTimeToKill)
                    gset("TimeToKill", time_to_kill)
            }

            ; update the last boss hp to be the current boss health
            last_boss_hp_percent := boss_hp_percent
            last_fast_hp := fast_hp
            Gdip_DisposeImage(pBitmap)
            Sleep 30
        }
        Else
            Sleep 100
    }
    gset("HighestDPS", "")
    gset("AverageDPS", "")
    gset("PercentHealth", "")
    gset("TotalHealth", "")
    stop_loop := 0
    tracking_active := false
    current_boss := ""
    set_tracker_state("idle")
    Return
}

calculate_kill_time()
{
    global
    if (dps_phase_active)
        gset("TimeToKill", time_to_kill)
}

show_damage_duration()
{
    global
    if (dps_phase_active)
        gset("DPSDuration", elapsed_time)
}

FormatWithCommas(number)
{
    return RegExReplace(number, "(\d)(?=(?:\d{3})+(?:\.|$))", "$1,")
}

ButtonOK(*)
{
    global settingsGui, stop_loop, tracking_active
    saved := settingsGui.Submit()
    ; make sure a previous tracker loop has fully exited before starting a
    ; new one - two concurrent loops corrupt each other's shared globals
    if (tracking_active)
    {
        stop_loop := 1
        deadline := A_TickCount + 2000
        while (tracking_active && A_TickCount < deadline)
            Sleep 50
    }
    calculateDPS(saved.BossName)
}

ButtonMeasure(*)
{
    global settingsGui
    saved := settingsGui.Submit()
    dmg := Trim(saved.MeasureDamage)
    if (!IsNumber(dmg) || dmg <= 0)
    {
        MsgBox "Enter the damage one hit deals (a number) before measuring."
        return
    }
    measure_boss_hp(dmg + 0, Trim(saved.MeasureName))
}

; measurement mode: the user hits the boss with a known-damage weapon in single,
; spaced shots; each hit removes a consistent chunk of the bar. we record the
; stable-to-stable drops, reject outliers (double hits, partial reads), and
; estimate max hp = damage_per_hit / average chunk fraction
measure_boss_hp(damage_per_hit, boss_name := "")
{
    global healthbar_location, stop_loop, boss_health_pool, boss_final_stand, boss_nobar, boss_variant

    stop_loop := 0
    chunks := []
    hist := []
    stable_count := 0
    last_reading := -1
    prev_stable := -1
    started := A_TickCount
    ToolTip "Measuring - land single spaced hits with the known weapon.`n"
        . "Ends after 12 hits or 60s (F2 finishes early).", 100, 100

    while (A_TickCount - started < 60000 && chunks.Length < 12 && !stop_loop)
    {
        pBitmap := Gdip_BitmapFromScreen(healthbar_location)
        raw := bossHealthPercentage(pBitmap)
        Gdip_DisposeImage(pBitmap)

        ; bar not visible (menu, death) - drop stability, don't fake a chunk
        if (raw <= 0)
        {
            stable_count := 0
            last_reading := -1
            Sleep 30
            continue
        }

        hist.Push(raw)
        if (hist.Length > 3)
            hist.RemoveAt(1)
        reading := (hist.Length = 3) ? median3(hist[1], hist[2], hist[3]) : raw

        if (last_reading >= 0 && Abs(reading - last_reading) <= 0.02)
            stable_count += 1
        else
            stable_count := 0
        last_reading := reading

        ; a value that held ~150ms counts as settled; the gap to the previous
        ; settled value is one hit's chunk
        if (stable_count >= 5)
        {
            if (prev_stable >= 0 && (prev_stable - reading) >= 0.05)
            {
                chunks.Push(prev_stable - reading)
                ToolTip "Hits recorded: " chunks.Length, 100, 100
            }
            prev_stable := reading
        }
        Sleep 30
    }
    stop_loop := 0
    ToolTip

    if (chunks.Length < 2)
    {
        MsgBox "Only " chunks.Length " clean hit(s) recorded - need at least 2.`n"
            . "Hit the boss with single, spaced shots while measuring."
        return
    }

    ; median chunk, drop outliers beyond 35%, average the rest
    sorted := chunks.Clone()
    loop sorted.Length - 1
    {
        i := A_Index
        loop sorted.Length - i
        {
            j := A_Index
            if (sorted[j] > sorted[j+1])
            {
                tmp := sorted[j], sorted[j] := sorted[j+1], sorted[j+1] := tmp
            }
        }
    }
    med := sorted[(sorted.Length + 1) // 2]
    sum := 0
    used := 0
    for c in chunks
    {
        if (Abs(c - med) <= med * 0.35)
        {
            sum += c
            used += 1
        }
    }
    avg := sum / used
    est_hp := Round(damage_per_hit / (avg / 100))

    result := used " clean hits (of " chunks.Length " recorded)`n"
        . "average chunk: " Round(avg, 3) "% of the bar`n"
        . "estimated boss HP: " FormatWithCommas(est_hp)
    A_Clipboard := est_hp

    if (boss_name != "")
    {
        entry_line := '"' boss_name '" = ' est_hp ' ,0'
        if (MsgBox(result "`n`nSave " entry_line " to Boss_full_name+HP.txt?", "Measurement", "YesNo") = "Yes")
        {
            FileAppend "`n" entry_line, A_ScriptDir "\Boss_full_name+HP.txt", "UTF-8-RAW"
            boss_health_pool[boss_name] := est_hp
            boss_final_stand[boss_name] := 0
            boss_nobar[boss_name] := 0
            boss_variant[boss_name] := "normal"
        }
    }
    else
        MsgBox result, "Measurement"
}

ShowSettingsGUI(*)
{
    global stop_loop, boss_list, boss_health_pool, settingsGui
    stop_loop := 1
    load_boss_data()  ; pick up any edits to the boss file
    ddl_items := []
    for key, _ in boss_health_pool
        ddl_items.Push(key)
    ; map iteration order is arbitrary - sort so the list is scannable
    sorted := ""
    for item in ddl_items
        sorted .= item "`n"
    ddl_items := StrSplit(Sort(RTrim(sorted, "`n")), "`n")
    settingsGui["BossName"].Delete()
    settingsGui["BossName"].Add(ddl_items)
    settingsGui.Show()
}

manualDPSPhase(*)
{
    global change_phase, manualDPSPhases
    if (manualDPSPhases)
        change_phase := 1
}

; ---- boss name detection ----
; reads the boss name rendered above the health bar with the windows built-in
; ocr engine, matches it against full_name_bosses.txt (on-screen name -> short
; name) and then boss_health.txt short names, and starts tracking that boss
; one ocr sweep over the name region with several preprocessing passes.
; the name is bright text over an arbitrary background, so binarizing at a
; high luminosity threshold usually erases the background entirely; no single
; threshold fits every scene, so we try a chain and keep the first match
ocr_detect_name()
{
    global bossname_location
    coords := StrSplit(bossname_location, "|")
    x := coords[1]+0, y := coords[2]+0, w := coords[3]+0, h := coords[4]+0
    static passes := [
        {scale: 2, monochrome: 190, invertcolors: 1},
        {scale: 2, monochrome: 150, invertcolors: 1},
        {scale: 3, monochrome: 220, invertcolors: 1},
        {scale: 2, grayscale: 1}]
    last_text := ""
    for opts in passes
    {
        try ocr_result := OCR.FromRect(x, y, w, h, opts)
        catch
            continue
        last_text := Trim(ocr_result.Text, " `n`r")
        match := match_boss_name(normalize_name(ocr_result.Text))
        if (match != "")
            return match
    }
    return ""
}

detect_boss(*)
{
    global switch_to_boss, tracking_active
    match := ""
    loop 5  ; a few frames apart - the name may be momentarily obscured
    {
        match := ocr_detect_name()
        if (match != "")
            break
        Sleep 150
    }
    if (match = "")
    {
        ToolTip "No boss detected", 100, 100
        SetTimer(clear_tooltip, -2000)
        return
    }
    ToolTip "Detected boss: " match, 100, 100
    SetTimer(clear_tooltip, -1500)
    if (tracking_active)
        switch_to_boss := match  ; running tracker retargets on its next tick
    else
        calculateDPS(match)
}

; background detection: when a bar is on screen, no damage phase is running and
; the tracked boss doesn't match what the screen says, retarget automatically
auto_detect_tick()
{
    global autoDetectBoss, dps_phase_active, currently_shown, tracking_active
    global current_boss, switch_to_boss, healthbar_location, stop_loop
    static nobar_since := 0, noname_since := 0
    if (!autoDetectBoss || dps_phase_active || !currently_shown)
    {
        nobar_since := 0
        noname_since := 0
        return
    }
    pBitmap := Gdip_BitmapFromScreen(healthbar_location)
    bar_visible := bossHealthPercentage(pBitmap) > 0
    Gdip_DisposeImage(pBitmap)
    ; watchdog, time-based so it's independent of the check interval: an idle
    ; tracker (no phase running) that sees no bar CONTINUOUSLY for 30s is
    ; stale - flush it back to the launch idle state; detection re-acquires
    ; the next boss. 30s is long enough that browsing the inventory (bar
    ; hidden the whole time) never trips it. a bar that IS on screen with an
    ; unreadable name is NOT stale: long mechanics stretches leave the bar
    ; frozen and the name obscured by effects/damage numbers for minutes -
    ; only something bar-like with no name for 5 straight minutes (the
    ; turquoise xp bar creeping through the bar row) gets flushed
    match := bar_visible ? ocr_detect_name() : ""
    if (match = "")
    {
        if (tracking_active)
        {
            if (!bar_visible)
            {
                noname_since := 0
                if (!nobar_since)
                    nobar_since := A_TickCount
                if (A_TickCount - nobar_since >= 30000)
                {
                    nobar_since := 0
                    stop_loop := 1
                    ToolTip "Boss tracker reset (no boss on screen)", 100, 100
                    SetTimer(clear_tooltip, -2000)
                }
            }
            else
            {
                nobar_since := 0
                if (!noname_since)
                    noname_since := A_TickCount
                if (A_TickCount - noname_since >= 300000)
                {
                    noname_since := 0
                    stop_loop := 1
                    ToolTip "Boss tracker reset (bar without a boss name)", 100, 100
                    SetTimer(clear_tooltip, -2000)
                }
            }
        }
        else
        {
            nobar_since := 0
            noname_since := 0
        }
        return
    }
    nobar_since := 0
    noname_since := 0
    if (tracking_active)
    {
        if (match != current_boss)
            switch_to_boss := match
    }
    else
        SetTimer(start_detected_tracker.Bind(match), -1)  ; host the loop in its own thread
}

start_detected_tracker(bossName)
{
    global tracking_active
    if (!tracking_active)
    {
        ToolTip "Detected boss: " bossName, 100, 100
        SetTimer(clear_tooltip, -1500)
        calculateDPS(bossName)
    }
}

; expects normalized ocr text; returns the boss data key or "".
; same-named variants (Pantheon / Epic) are resolved by encounterContext;
; bosses without a bottom hp bar are never matched
match_boss_name(ocr_text)
{
    global boss_health_pool, boss_nobar, boss_variant, encounterContext
    if (ocr_text = "")
        return ""

    best := ""
    best_len := 0
    best_pref := -1
    for key, _ in boss_health_pool
    {
        if (boss_nobar.Get(key, 0))
            continue
        ; the %-mode pseudo-bosses are picked manually, never by detection
        if (key = "default" || key = "default with final stand")
            continue
        display_name := RegExReplace(key, " \[(Pantheon|Epic)\]$", "")
        norm := normalize_name(display_name)
        if (StrLen(norm) < 4)
            continue
        ; full containment either way; a partial ocr read may be contained in
        ; the name (needs some length to be trusted)
        hit := InStr(ocr_text, norm) || (StrLen(ocr_text) >= 8 && InStr(norm, ocr_text))
        if (!hit)
            continue
        variant := boss_variant.Get(key, "normal")
        pref := (variant = encounterContext) ? 2 : (variant = "normal") ? 1 : 0
        if (StrLen(norm) > best_len || (StrLen(norm) = best_len && pref > best_pref))
        {
            best := key
            best_len := StrLen(norm)
            best_pref := pref
        }
    }
    return best
}

; cycle normal -> epic -> pantheon; picks between same-named boss variants
cycle_encounter_context(*)
{
    global encounterContext
    encounterContext := (encounterContext = "normal") ? "epic" : (encounterContext = "epic") ? "pantheon" : "normal"
    ToolTip "Encounter context: " encounterContext, 100, 100
    SetTimer(clear_tooltip, -1500)
}

; lowercase, fold accents, delete punctuation (C.A.R.L. -> carl), collapse spaces
normalize_name(s)
{
    static accents := Map("û","u","ü","u","ú","u","ù","u","é","e","è","e","ê","e","ë","e",
        "á","a","à","a","â","a","ä","a","í","i","ì","i","î","i","ï","i",
        "ó","o","ò","o","ô","o","ö","o","ñ","n","ç","c","š","s","ž","z")
    s := StrLower(s)
    for k, v in accents
        s := StrReplace(s, k, v)
    s := RegExReplace(s, "\s+", " ")
    s := RegExReplace(s, "[^a-z0-9 ]", "")
    return Trim(RegExReplace(s, " {2,}", " "))
}

clear_tooltip()
{
    ToolTip
}

reload_the_script(*)
{
    Reload
}

close_the_script(*)
{
    ExitApp
}

; legacy 90s damage test - only bound if Damage Test Hotkey is set
damage_test_start(*)
{
    global sleep_time_seconds := 90
    global startTime := A_TickCount
    global beast := ""
    global start_damage := percent_dealt
    SetTimer(damage_test, sleep_time_seconds*1000)
    SetTimer(increment_damage, 50)
}

increment_damage()
{
    global beast
    temp_var := (percent_dealt - start_damage)*boss_max_hp
    beast := beast "`n" (A_TickCount - startTime) . "," . temp_var
}

damage_test()
{
    global
    SetTimer(damage_test, 0)
    SetTimer(increment_damage, 0)
    damage_done := FormatWithCommas(Round((percent_dealt - start_damage)*boss_max_hp, 0))
    temp_dps := FormatWithCommas(Round((percent_dealt - start_damage)*boss_max_hp/sleep_time_seconds, 0))
    info := damage_done " damage dealt in " sleep_time_seconds " seconds`n " temp_dps " DPS"
    A_Clipboard := info "`n" beast
    MsgBox info

    ; Save the data to a CSV file
    try FileDelete "dps.csv" ; delete the old file if it exists
    time := SubStr(A_Hour "-" A_Min "-" A_Sec, 1, 8)
    FileAppend beast, time ".csv"
}


#HotIf edit_mode && MouseIsOverGraph()
WheelUp::graph_resize(1.08)
WheelDown::graph_resize(1 / 1.08)
#HotIf

^Esc::ExitApp
