; AHK v2 - Beispiel Producer für den DX11 Overlay Queue-Writer.
; Rolle: Memory/W2S/Entity-Logik -> RenderOps in Shared Queue schreiben.

#Include RenderQueueBridge.ahk

class PoE2OverlayProducer {
    __New() {
        this.bridge := GH2RenderQueueBridge()
        this.enabled := true
    }

    Tick() {
        if (!this.enabled)
            return

        ; TODO: Hier echte Daten aus GameReader einsetzen.
        ; Beispiel: statischer Healthbar + Text als Smoke-Test.
        this.bridge.PushText(100, 90, "Producer alive", 0xFFFFFFFF)
        this.bridge.PushHealthBar(100, 110, 200, 10, 0.75, 0xFF00FF00)
    }

    RunLoop() {
        while (this.enabled) {
            this.Tick()
            Sleep(16) ; ~60 FPS enqueue cadence
        }
    }
}

producer := PoE2OverlayProducer()
producer.RunLoop()
