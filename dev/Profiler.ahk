; Profiler.ahk
; Sub-millisecond per-label timing via QueryPerformanceCounter.
; Included by InGameStateMonitor.ahk

class ProfilerClass
{
    Enabled := true
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

global Profiler := ProfilerClass()
