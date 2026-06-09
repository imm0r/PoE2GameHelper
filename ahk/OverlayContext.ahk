; OverlayContext.ahk
; Lightweight per-tick value object shared by every overlay through OverlayManager.
; A single instance is owned by the manager and its fields are refreshed each tick
; by the driver (UpdateRadarFast), so there is no per-frame allocation on the hot path.
; Carries the snapshot, the resolved game-window rectangle, foreground state and the
; computed play-overlay gate result. Overlays read from it in ShouldShow/Layout/Draw.
; Included by InGameStateMonitor.ahk (after the overlay subclasses, before OverlayManager).

class OverlayContext
{
    __New()
    {
        this.snapshot           := 0       ; radar snapshot Map for this tick (may be stale within grace)
        this.reader             := 0       ; PoE2 reader (FocusOverlay needs live reads)
        this.gameHwnd           := 0       ; resolved PoE window handle (0 when not found)
        this.gwX                := 0
        this.gwY                := 0
        this.gwW                := 0
        this.gwH                := 0
        this.gameActive         := false   ; PoE window is the foreground window
        this.toolFocused        := false   ; our own WebView tool window is focused
        this.keepWhenBackground := false   ; show play overlays even when game isn't active (tool focus / range circles)
        this.inspectOverride    := false   ; UI-browser inspect mode forces play overlays visible
        this.paused             := false   ; global updates-paused flag
        this.currentState       := ""      ; current game state name (e.g. "InGameState")
        this.gate               := Map("allowed", false, "allowedNoMap", false, "reason", "")  ; play-overlay gate result
    }
}
