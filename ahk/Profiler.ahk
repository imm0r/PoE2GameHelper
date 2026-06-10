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
        hdr := Format("{:-28s}  {:>6s}  {:>8s}  {:>8s}  {:>8s}  {:>8s}",
                      "Label", "Calls", "Last µs", "Avg µs", "Min µs", "Max µs")
        sep := "-----------------------------  ------  --------  --------  --------  --------"
        out := hdr . NL . sep . NL
        for label, e in this._labels
        {
            avgUs := (e.count > 0) ? Round(e.totalUs / e.count) : 0
            minUs := (e.minUs = 9999999999) ? 0 : e.minUs
            out .= Format("{:-28s}  {:>6d}  {:>8d}  {:>8d}  {:>8d}  {:>8d}",
                          label, e.count, e.lastUs, avgUs, minUs, e.maxUs) . NL
        }
        return out
    }

    Reset()
    {
        this._labels := Map()
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
}

; Shift+F3 handler. Two-press measurement flow so the profiler only runs during the
; window you care about (no always-on cost):
;   1st press -> reset + enable; reproduce the stutter.
;   2nd press -> snapshot the table to logs\profiler_<ts>.txt, show it as a tooltip,
;                then disable again.
ProfilerToggleDump()
{
    global Profiler
    if (!IsSet(Profiler) || !IsObject(Profiler))
        return

    if !Profiler.Enabled
    {
        Profiler.Reset()
        Profiler.Enabled := true
        ToolTip("Profiler: ON - reproduce the lag, then press Shift+F3 again to dump.")
        SetTimer(() => ToolTip(), -4000)
        return
    }

    ; Second press: stop measuring, then persist + show the collected table.
    Profiler.Enabled := false
    summary := Profiler.Summary()
    ts      := FormatTime(A_Now, "yyyy-MM-dd_HH-mm-ss")
    outPath := A_ScriptDir "\logs\profiler_" ts ".txt"
    try
    {
        DirCreate(A_ScriptDir "\logs")
        FileAppend(summary "`n", outPath, "UTF-8")
    }
    ToolTip("Profiler: OFF - saved to`n" outPath "`n`n" summary)
    SetTimer(() => ToolTip(), -10000)
}
