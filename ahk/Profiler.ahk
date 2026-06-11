; Profiler.ahk
; Sub-millisecond per-label timing via QueryPerformanceCounter.
; Included by InGameStateMonitor.ahk

class ProfilerClass
{
    ; Disabled by default so the per-tick Begin/End markers cost a single
    ; property read + early return (zero measurable overhead). A debug hotkey
    ; (Shift+F3 -> ProfilerToggleDump) flips it on for a measurement window.
    Enabled := false
    _freq   := 0
    _labels := Map()

    __New()
    {
        freq := Buffer(8, 0)
        DllCall("QueryPerformanceFrequency", "Ptr", freq)
        this._freq := NumGet(freq, 0, "Int64")
    }

    Begin(label)
    {
        if !this.Enabled
            return
        try
        {
            qpc := Buffer(8, 0)
            DllCall("QueryPerformanceCounter", "Ptr", qpc)
            if !this._labels.Has(label)
                this._labels[label] := {count: 0, totalUs: 0, minUs: 9999999999,
                                        maxUs: 0, lastUs: 0, startQpc: 0}
            this._labels[label].startQpc := NumGet(qpc, 0, "Int64")
        }
        catch
        {
        }
    }

    End(label)
    {
        if !this.Enabled
            return
        try
        {
            qpc := Buffer(8, 0)
            DllCall("QueryPerformanceCounter", "Ptr", qpc)
            now := NumGet(qpc, 0, "Int64")
            if !this._labels.Has(label)
                return
            e := this._labels[label]
            if (e.startQpc = 0)
                return
            elapsed   := Round((now - e.startQpc) * 1000000 / this._freq)
            e.count   += 1
            e.totalUs += elapsed
            e.lastUs   := elapsed
            if (elapsed < e.minUs)
                e.minUs := elapsed
            if (elapsed > e.maxUs)
                e.maxUs := elapsed
            e.startQpc := 0
        }
        catch
        {
        }
    }

    Summary()
    {
        if (this._labels.Count = 0)
            return "(no profiler data)"
        NL  := "`n"
        ; AHK's Format() is printf-style: right-align is the default (no flag),
        ; left-align is "-". Python-style ">" is NOT understood and would be
        ; emitted literally, so widths are given as bare numbers here.
        hdr := Format("{:-28s}  {:6s}  {:8s}  {:8s}  {:8s}  {:8s}",
                      "Label", "Calls", "Last us", "Avg us", "Min us", "Max us")
        sep := "-----------------------------  ------  --------  --------  --------  --------"
        out := hdr . NL . sep . NL
        for label, e in this._labels
        {
            avgUs := (e.count > 0) ? Round(e.totalUs / e.count) : 0
            minUs := (e.minUs = 9999999999) ? 0 : e.minUs
            out .= Format("{:-28s}  {:6d}  {:8d}  {:8d}  {:8d}  {:8d}",
                          label, e.count, e.lastUs, avgUs, minUs, e.maxUs) . NL
        }
        return out
    }

    Reset()
    {
        this._labels := Map()
    }

    ; Returns a one-line headline naming the single most expensive marker by
    ; average time, e.g. "read.entities 41.2ms" — shown on the status pill while
    ; the full table lives in its hover tooltip. "(no data)" when nothing ran.
    Headline()
    {
        if (this._labels.Count = 0)
            return "(no data)"
        bestLabel := "", bestAvg := -1.0
        for label, e in this._labels
        {
            avg := (e.count > 0) ? (e.totalUs / e.count) : 0
            if (avg > bestAvg)
            {
                bestAvg := avg
                bestLabel := label
            }
        }
        return bestLabel " " Round(bestAvg / 1000, 1) "ms"
    }
}

; Constructs the global Profiler singleton, disabled by default. Called once from
; the main auto-execute section. The top-level `global Profiler := ...` pattern is
; intentionally avoided here: this module is #Include'd after the main script's
; auto-execute return, so such an initializer would never run (AHK v2 init gotcha,
; see CLAUDE.md). Every marker site declares `global Profiler` to reach it.
InitProfiler()
{
    global Profiler := ProfilerClass()
    Profiler.Enabled := false
    ; Status-pill dump state (read by _PushProfilerPill -> updateProfilerPill in the UI):
    ;   "idle"      -> pill shows the live fps (driven by UpdateStatusBar)
    ;   "recording" -> a measurement window is open (1st Shift+F3)
    ;   "done"      -> headline on the pill, full table in its hover tooltip (2nd Shift+F3)
    global g_profDumpState    := "idle"
    global g_profDumpHeadline := ""
    global g_profDumpTable    := ""
}

; Pushes the current profiler dump state to the status pill in the WebView. Safe to
; call from the in-game Shift+F3 handler — WebViewExec reaches the control regardless
; of focus; it just no-ops until the page is ready.
_PushProfilerPill()
{
    global g_webViewReady, g_profDumpState, g_profDumpHeadline, g_profDumpTable
    if !(IsSet(g_webViewReady) && g_webViewReady)
        return
    try WebViewExec("updateProfilerPill("
        . _JsStr(g_profDumpState) "," _JsStr(g_profDumpHeadline) "," _JsStr(g_profDumpTable) ")")
}

; Profiler toggle — invoked by clicking the ⏱ status pill (ProfilerToggle bridge case).
; Two-click measurement flow so the profiler only runs during the window you care about
; (no always-on cost):
;   1st click -> reset + enable; the status pill shows "REC". Reproduce the stutter.
;   2nd click -> snapshot the table to the status pill (headline + full table in its
;                hover tooltip), then disable again. No file, no in-game tooltip.
ProfilerToggleDump()
{
    global Profiler, g_profDumpState, g_profDumpHeadline, g_profDumpTable
    if (!IsSet(Profiler) || !IsObject(Profiler))
        return

    if !Profiler.Enabled
    {
        Profiler.Reset()
        Profiler.Enabled := true
        g_profDumpState    := "recording"
        g_profDumpHeadline := "● REC"
        g_profDumpTable    := ""
        _PushProfilerPill()
        return
    }

    ; Second press: stop measuring, surface the collected table on the pill.
    Profiler.Enabled := false
    g_profDumpState    := "done"
    g_profDumpHeadline := Profiler.Headline()
    g_profDumpTable    := Profiler.Summary()
    _PushProfilerPill()
}
