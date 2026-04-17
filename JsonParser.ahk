; JsonParser.ahk
; Minimal JSON parser for the WebView bridge message protocol.
; Handles flat {key:value} objects and arrays of strings/numbers/booleans.
;
; Included by InGameStateMonitor.ahk

; Parses a JSON string into an AHK Map (for objects) or Array (for arrays).
; Only supports flat objects and simple arrays — not a general-purpose parser.
_JsonParseSimple(json)
{
    json := Trim(json)
    if (SubStr(json, 1, 1) = "{")
    {
        result := Map()
        inner := SubStr(json, 2, StrLen(json) - 2)
        pos := 1
        while (pos <= StrLen(inner))
        {
            ; Skip whitespace and commas
            while (pos <= StrLen(inner) && InStr(", `t`r`n", SubStr(inner, pos, 1)))
                pos++
            if (pos > StrLen(inner))
                break
            ; Read quoted key
            if (SubStr(inner, pos, 1) != '"')
                break
            pos++
            keyEnd := InStr(inner, '"', true, pos)
            if !keyEnd
                break
            key := SubStr(inner, pos, keyEnd - pos)
            pos := keyEnd + 1
            ; Skip colon and whitespace
            while (pos <= StrLen(inner) && InStr(": `t", SubStr(inner, pos, 1)))
                pos++
            ; Read value (string, number, bool, array, or nested object)
            valResult := _JsonReadValue(inner, pos)
            result[key] := valResult[1]
            pos := valResult[2]
        }
        return result
    }
    if (SubStr(json, 1, 1) = "[")
        return _JsonReadArray(json, 1)[1]
    return json
}

; Reads a single JSON value starting at position pos in string s.
; Returns: [parsedValue, newPosition]
_JsonReadValue(s, pos)
{
    ch := SubStr(s, pos, 1)
    if (ch = '"')
    {
        ; Quoted string — handle escape sequences
        pos++
        start := pos
        while (pos <= StrLen(s))
        {
            c := SubStr(s, pos, 1)
            if (c = "\" )
            {
                pos += 2
                continue
            }
            if (c = '"')
                break
            pos++
        }
        val := SubStr(s, start, pos - start)
        val := StrReplace(val, "\n", "`n")
        val := StrReplace(val, "\t", "`t")
        val := StrReplace(val, '\"', '"')
        val := StrReplace(val, "\\", "\")
        return [val, pos + 1]
    }
    if (ch = "[")
        return _JsonReadArray(s, pos)
    if (ch = "{")
    {
        ; Nested object — skip balanced braces and return empty Map
        depth := 0
        start := pos
        while (pos <= StrLen(s))
        {
            c := SubStr(s, pos, 1)
            if (c = "{")
                depth++
            else if (c = "}")
            {
                depth--
                if (depth = 0)
                {
                    pos++
                    break
                }
            }
            pos++
        }
        return [Map(), pos]
    }
    ; Number, boolean, or null literal
    end := pos
    while (end <= StrLen(s) && !InStr(",]}", SubStr(s, end, 1)))
        end++
    raw := Trim(SubStr(s, pos, end - pos))
    if (raw = "true")
        return [true,  end]
    if (raw = "false")
        return [false, end]
    if (raw = "null")
        return ["",    end]
    return [IsNumber(raw) ? raw + 0 : raw, end]
}

; Reads a JSON array starting at position pos in string s.
; Returns: [arrayOfValues, newPosition]
_JsonReadArray(s, pos)
{
    result := []
    pos++  ; skip opening [
    while (pos <= StrLen(s))
    {
        ; Skip whitespace and commas
        while (pos <= StrLen(s) && InStr(", `t`r`n", SubStr(s, pos, 1)))
            pos++
        if (SubStr(s, pos, 1) = "]")
        {
            pos++
            break
        }
        valResult := _JsonReadValue(s, pos)
        result.Push(valResult[1])
        pos := valResult[2]
    }
    return [result, pos]
}
