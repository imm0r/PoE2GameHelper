; AHK v2 - Shared RenderQueue producer for DX11 overlay DLL.
class GH2RenderQueueBridge {
    static MAP_NAME := "Local\\PoE2GH_RenderQueue_v1"
    static MUTEX_NAME := "Local\\PoE2GH_RenderQueueMutex_v1"
    static CAPACITY := 2048
    static MAGIC := 0x51475248
    static OP_SIZE := 124
    static TEXT_SIZE := 96

    __New() {
        this.hMap := DllCall("CreateFileMappingW", "ptr", -1, "ptr", 0, "uint", 0x04, "uint", 0, "uint", this.__MapSize(), "str", GH2RenderQueueBridge.MAP_NAME, "ptr")
        if (!this.hMap)
            throw Error("CreateFileMappingW failed")

        this.pView := DllCall("MapViewOfFile", "ptr", this.hMap, "uint", 0xF001F, "uint", 0, "uint", 0, "uptr", this.__MapSize(), "ptr")
        if (!this.pView)
            throw Error("MapViewOfFile failed")

        this.hMutex := DllCall("CreateMutexW", "ptr", 0, "int", 0, "str", GH2RenderQueueBridge.MUTEX_NAME, "ptr")
        if (!this.hMutex)
            throw Error("CreateMutexW failed")

        this.__EnsureHeader()
    }

    __Delete() {
        if (this.pView)
            DllCall("UnmapViewOfFile", "ptr", this.pView)
        if (this.hMap)
            DllCall("CloseHandle", "ptr", this.hMap)
        if (this.hMutex)
            DllCall("CloseHandle", "ptr", this.hMutex)
    }

    PushFilledRect(x, y, w, h, argb := 0xFF00FF00) {
        this.__PushOp(2, x, y, w, h, 0.0, argb, "")
    }

    PushHealthBar(x, y, w, h, pct, argb := 0xFF00FF00) {
        this.__PushOp(4, x, y, w, h, pct, argb, "")
    }

    PushText(x, y, text, argb := 0xFFFFFFFF) {
        this.__PushOp(3, x, y, 0.0, 0.0, 0.0, argb, text)
    }

    __MapSize() => 12 + (GH2RenderQueueBridge.CAPACITY * GH2RenderQueueBridge.OP_SIZE)

    __EnsureHeader() {
        DllCall("RtlMoveMemory", "ptr", buf := Buffer(4), "ptr", this.pView, "uptr", 4)
        magic := NumGet(buf, 0, "uint")
        if (magic != GH2RenderQueueBridge.MAGIC) {
            NumPut("uint", GH2RenderQueueBridge.MAGIC, this.pView, 0)
            NumPut("uint", 0, this.pView, 4)
            NumPut("uint", 0, this.pView, 8)
        }
    }

    __PushOp(type, x, y, w, h, value, color, text) {
        if (DllCall("WaitForSingleObject", "ptr", this.hMutex, "uint", 5, "uint") != 0)
            return false
        try {
            writeIndex := NumGet(this.pView, 4, "uint")
            count := NumGet(this.pView, 8, "uint")
            offset := 12 + (writeIndex * GH2RenderQueueBridge.OP_SIZE)

            NumPut("uint", type, this.pView, offset + 0)
            NumPut("float", x, this.pView, offset + 4)
            NumPut("float", y, this.pView, offset + 8)
            NumPut("float", w, this.pView, offset + 12)
            NumPut("float", h, this.pView, offset + 16)
            NumPut("float", value, this.pView, offset + 20)
            NumPut("uint", color, this.pView, offset + 24)

            text := SubStr(text, 1, 95)
            textBuf := Buffer(GH2RenderQueueBridge.TEXT_SIZE, 0)
            StrPut(text, textBuf, "CP0")
            DllCall("RtlMoveMemory", "ptr", this.pView + offset + 28, "ptr", textBuf, "uptr", GH2RenderQueueBridge.TEXT_SIZE)

            writeIndex := Mod(writeIndex + 1, GH2RenderQueueBridge.CAPACITY)
            count := Min(count + 1, GH2RenderQueueBridge.CAPACITY)
            NumPut("uint", writeIndex, this.pView, 4)
            NumPut("uint", count, this.pView, 8)
            return true
        } finally {
            DllCall("ReleaseMutex", "ptr", this.hMutex)
        }
    }
}
