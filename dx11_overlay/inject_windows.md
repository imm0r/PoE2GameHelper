# Inject Checklist (Windows)

## 1) Vorbedingungen

- `PoE2DX11Overlay.dll` wurde erfolgreich gebaut (`build/Release`).
- Zielprozess `PoE2.exe` läuft bereits (DX11 Renderpfad aktiv).
- Der Producer (AHK) schreibt RenderOps in die Shared Queue.

## 2) Reihenfolge (empfohlen)

1. Spiel starten und in eine Szene laden (damit SwapChain sicher vorhanden ist).
2. DLL in `PoE2.exe` injizieren.
3. Danach AHK Producer starten (oder Producer vorab starten, wenn Queue bereits initialisiert ist).
4. Sichtprüfung: z. B. `PushText`/`PushHealthBar` an feste Bildschirmposition.

## 3) Quick Smoke Test (AHK)

```ahk
bridge := GH2RenderQueueBridge()
Loop 300 {
    bridge.PushText(120, 120, "DX11 Hook alive", 0xFF00FFFF)
    bridge.PushHealthBar(120, 145, 220, 10, 0.66, 0xFF00FF00)
    Sleep 16
}
```

## 4) Wenn kein Overlay sichtbar ist

- Prüfen, ob das Spiel wirklich mit DX11 läuft.
- Prüfen, ob Injektion erfolgreich war (Injector-Log / Modul-Liste im Prozess).
- Prüfen, ob `RenderQueue` befüllt wird (temporär Producer mit statischem Text laufen lassen).
- Im Windowed/Borderless testen (einige Vollbildpfade reagieren empfindlich).
- Nach Auflösungswechsel erneut prüfen (`ResizeBuffers` Hook sollte RTV neu erstellen).

## 5) Typische Symptome

- **DLL injiziert, aber nichts gezeichnet**: Queue leer oder Hook nicht aktiv.
- **Nur kurz sichtbar, dann weg**: Device/SwapChain-Wechsel, erneute Injektion testen.
- **Flackern/Artefakte**: Mehrfach-Injektion oder Konflikt mit anderem Overlay/Hook.

## 6) Stabilitäts-Hinweise

- Nur **eine** Instanz der Overlay-DLL pro Prozess injizieren.
- Producer-Schreiblast begrenzen (nur notwendige Ops pro Frame senden).
- Für Debug zunächst wenige primitive DrawOps verwenden (Text + 1 Bar).
