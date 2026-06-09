; OverlayManager.ahk
; Central registry + per-tick driver for the whole overlay system. Owns every
; overlay instance, the shared OverlayContext and the PlayOverlayPolicy. The radar
; hot path (UpdateRadarFast) just refreshes the context fields and calls Tick(ctx);
; the manager evaluates the play-overlay gate once and drives each overlay through
; its uniform Update(ctx) contract (Enabled -> ShouldShow -> Layout -> Draw -> Blit).
;
; Adding a new overlay is a two-line change: subclass GdiOverlayBase and Register()
; it here -- no new global, no new driver wiring, no new toggle plumbing.
; Included by InGameStateMonitor.ahk (after OverlayContext + PlayOverlayPolicy).

class OverlayManager
{
    __New()
    {
        this._overlays := []          ; draw order
        this._byName   := Map()       ; name -> overlay
        this._policy   := PlayOverlayPolicy()
        this.context   := OverlayContext()

        ; Register the built-in overlays. Order = draw/registration order.
        this.Register(RadarOverlay())
        this.Register(PlayerHUD())
        this.Register(NotificationOverlay())
        this.Register(FocusOverlay())
    }

    ; Registers an overlay instance and indexes it by its Name.
    Register(ov)
    {
        this._overlays.Push(ov)
        this._byName[ov.Name] := ov
    }

    ; Returns the overlay registered under name, or 0 if none.
    Get(name) => this._byName.Has(name) ? this._byName[name] : 0

    ; Drives all overlays for this tick. Evaluates the shared play-overlay gate
    ; once and stores it on ctx.gate, then runs each overlay's Update(ctx). A
    ; faulty overlay can never break the others or the timer callback.
    Tick(ctx)
    {
        if ctx.paused
        {
            this.HideAll()
            return
        }
        this._EvaluateGate(ctx)
        for ov in this._overlays
        {
            try ov.Update(ctx)
            catch as e
                LogError("Overlay:" ov.Name, e)
        }
    }

    ; Fills the ctx fields the policy derives from overlay state, then evaluates
    ; the play-overlay gate (radar + HUD share it via ShouldShow => ctx.gate).
    _EvaluateGate(ctx)
    {
        global g_uiBrowserHighlight
        ; Keep the overlay visible while the game isn't focused ONLY when our own
        ; PoEformance UI is focused (so range circles etc. preview while you tweak
        ; settings). Alt-tabbing to any other window hides it, even with range
        ; circles enabled.
        ctx.keepWhenBackground := ctx.toolFocused
        ctx.inspectOverride    := IsSet(g_uiBrowserHighlight) && IsObject(g_uiBrowserHighlight)
        ctx.gate := this._policy.Evaluate(ctx)
    }

    ; Hides every overlay (used on pause / hard snapshot failure).
    HideAll()
    {
        for ov in this._overlays
            try ov.Hide()
    }
}

; Builds the OverlayManager (which constructs + registers every overlay) and points
; the legacy g_* overlay globals at the manager-owned instances so existing call
; sites (CombatAutomation, WebViewBridge, EntityAlerts, BridgeDispatch, …) keep
; working unchanged. Called once from InGameStateMonitor before the main return, so
; the AHK v2 module-init gotcha (top-level globals in #Include'd modules don't run)
; does not apply.
LoadOverlaySystem()
{
    global g_overlayManager, g_radarOverlay, g_playerHud, g_notifyOverlay, g_focusOverlay, g_radarAlpha
    g_overlayManager := OverlayManager()
    g_radarOverlay   := g_overlayManager.Get("radar")
    g_playerHud      := g_overlayManager.Get("playerHud")
    g_notifyOverlay  := g_overlayManager.Get("notification")
    g_focusOverlay   := g_overlayManager.Get("focus")
    if (IsSet(g_radarAlpha) && g_radarOverlay)
        g_radarOverlay.SetAlpha(g_radarAlpha)
}
