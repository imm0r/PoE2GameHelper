; JsonFull.ahk
; Recursive JSON parser and serializer for nested objects/arrays.
; The existing JsonParser.ahk only handles flat objects (it returns an empty
; Map for nested values), which is insufficient for the custom-hotkey config
; (groups -> hotkeys -> actions). This module round-trips arbitrary nesting.
;
; Conventions:
;   - JSON objects  -> AHK Map
;   - JSON arrays   -> AHK Array
;   - JSON strings  -> AHK String
;   - JSON numbers  -> AHK Number (Integer or Float)
;   - true/false    -> AHK 1 / 0 (AHK v2 has no dedicated boolean type)
;   - null          -> "" (empty string)
;
; Included by InGameStateMonitor.ahk

; Parses a JSON string into a nested AHK Map/Array structure.
; Params: jsonText - the JSON source string.
; Returns: Map / Array / primitive, or "" on parse failure.
JsonFull_Parse(jsonText)
{
    state := Map("s", jsonText, "pos", 1, "len", StrLen(jsonText))
    try
    {
        _JsonFull_SkipWs(state)
        val := _JsonFull_ReadValue(state)
        _JsonFull_SkipWs(state)
        return val
    }
    catch
        return ""
}

; Serializes a nested AHK Map/Array/primitive into a JSON string.
; Params: value - the structure to serialize; pretty - when true, indents output.
; Returns: a JSON string.
JsonFull_Stringify(value, pretty := false)
{
    return _JsonFull_Write(value, pretty, 0)
}

; Advances state["pos"] past any whitespace characters.
_JsonFull_SkipWs(state)
{
    s := state["s"]
    len := state["len"]
    pos := state["pos"]
    while (pos <= len)
    {
        c := SubStr(s, pos, 1)
        if (c = " " || c = "`t" || c = "`r" || c = "`n")
            pos++
        else
            break
    }
    state["pos"] := pos
}

; Reads a single JSON value (object, array, string, number, bool, null) from state.
; Returns: the parsed value; advances state["pos"].
_JsonFull_ReadValue(state)
{
    _JsonFull_SkipWs(state)
    s := state["s"]
    pos := state["pos"]
    c := SubStr(s, pos, 1)

    if (c = "{")
        return _JsonFull_ReadObject(state)
    if (c = "[")
        return _JsonFull_ReadArray(state)
    if (c = '"')
        return _JsonFull_ReadString(state)

    ; Literal: true / false / null / number
    if (SubStr(s, pos, 4) = "true")
    {
        state["pos"] := pos + 4
        return 1
    }
    if (SubStr(s, pos, 5) = "false")
    {
        state["pos"] := pos + 5
        return 0
    }
    if (SubStr(s, pos, 4) = "null")
    {
        state["pos"] := pos + 4
        return ""
    }
    return _JsonFull_ReadNumber(state)
}

; Reads a JSON object {"k": v, ...} into an AHK Map.
_JsonFull_ReadObject(state)
{
    result := Map()
    state["pos"]++   ; skip {
    _JsonFull_SkipWs(state)
    if (SubStr(state["s"], state["pos"], 1) = "}")
    {
        state["pos"]++
        return result
    }
    loop
    {
        _JsonFull_SkipWs(state)
        key := _JsonFull_ReadString(state)
        _JsonFull_SkipWs(state)
        ; skip colon
        if (SubStr(state["s"], state["pos"], 1) = ":")
            state["pos"]++
        val := _JsonFull_ReadValue(state)
        result[key] := val
        _JsonFull_SkipWs(state)
        ch := SubStr(state["s"], state["pos"], 1)
        if (ch = ",")
        {
            state["pos"]++
            continue
        }
        if (ch = "}")
        {
            state["pos"]++
            break
        }
        ; Malformed — bail to avoid infinite loop.
        break
    }
    return result
}

; Reads a JSON array [v, ...] into an AHK Array.
_JsonFull_ReadArray(state)
{
    result := []
    state["pos"]++   ; skip [
    _JsonFull_SkipWs(state)
    if (SubStr(state["s"], state["pos"], 1) = "]")
    {
        state["pos"]++
        return result
    }
    loop
    {
        val := _JsonFull_ReadValue(state)
        result.Push(val)
        _JsonFull_SkipWs(state)
        ch := SubStr(state["s"], state["pos"], 1)
        if (ch = ",")
        {
            state["pos"]++
            continue
        }
        if (ch = "]")
        {
            state["pos"]++
            break
        }
        break
    }
    return result
}

; Reads a quoted JSON string, decoding escape sequences.
_JsonFull_ReadString(state)
{
    s := state["s"]
    len := state["len"]
    pos := state["pos"]
    if (SubStr(s, pos, 1) != '"')
        return ""
    pos++   ; skip opening quote
    out := ""
    while (pos <= len)
    {
        c := SubStr(s, pos, 1)
        if (c = '"')
        {
            pos++
            break
        }
        if (c = "\")
        {
            esc := SubStr(s, pos + 1, 1)
            switch esc
            {
                case '"': out .= '"'
                case "\": out .= "\"
                case "/": out .= "/"
                case "n": out .= "`n"
                case "r": out .= "`r"
                case "t": out .= "`t"
                case "b": out .= Chr(8)
                case "f": out .= Chr(12)
                case "u":
                    hex := SubStr(s, pos + 2, 4)
                    out .= Chr(Integer("0x" hex))
                    pos += 4
                default:
                    out .= esc
            }
            pos += 2
            continue
        }
        out .= c
        pos++
    }
    state["pos"] := pos
    return out
}

; Reads a JSON number literal and returns it as an AHK Number.
_JsonFull_ReadNumber(state)
{
    s := state["s"]
    len := state["len"]
    pos := state["pos"]
    start := pos
    while (pos <= len)
    {
        c := SubStr(s, pos, 1)
        if (InStr("0123456789+-.eE", c))
            pos++
        else
            break
    }
    raw := SubStr(s, start, pos - start)
    state["pos"] := pos
    if (raw = "" || !IsNumber(raw))
        return 0
    return raw + 0
}

; Recursively writes an AHK value as JSON. Internal helper for JsonFull_Stringify.
_JsonFull_Write(value, pretty, depth)
{
    if (IsObject(value))
    {
        if (value is Array)
            return _JsonFull_WriteArray(value, pretty, depth)
        if (value is Map)
            return _JsonFull_WriteObject(value, pretty, depth)
        ; Unsupported object type — emit null.
        return "null"
    }
    ; Only genuine numeric types are emitted unquoted; numeric-looking strings
    ; (e.g. the key name "1") must stay quoted to round-trip as strings.
    if (value is Integer || value is Float)
        return value ""
    ; Treat everything else as a string.
    return _JsonFull_QuoteString(value "")
}

; Writes an AHK Map as a JSON object.
_JsonFull_WriteObject(m, pretty, depth)
{
    if (m.Count = 0)
        return "{}"
    nl := pretty ? "`n" : ""
    pad := pretty ? _JsonFull_Indent(depth + 1) : ""
    padEnd := pretty ? _JsonFull_Indent(depth) : ""
    parts := []
    for k, v in m
        parts.Push(pad _JsonFull_QuoteString(k "") ":" (pretty ? " " : "") _JsonFull_Write(v, pretty, depth + 1))
    body := ""
    for i, p in parts
        body .= (i > 1 ? ("," nl) : "") p
    return "{" nl body nl padEnd "}"
}

; Writes an AHK Array as a JSON array.
_JsonFull_WriteArray(a, pretty, depth)
{
    if (a.Length = 0)
        return "[]"
    nl := pretty ? "`n" : ""
    pad := pretty ? _JsonFull_Indent(depth + 1) : ""
    padEnd := pretty ? _JsonFull_Indent(depth) : ""
    body := ""
    for i, v in a
        body .= (i > 1 ? ("," nl) : "") pad _JsonFull_Write(v, pretty, depth + 1)
    return "[" nl body nl padEnd "]"
}

; Returns an indentation string of <depth> levels (2 spaces each).
_JsonFull_Indent(depth)
{
    out := ""
    loop depth
        out .= "  "
    return out
}

; Quotes and escapes a string for JSON output.
_JsonFull_QuoteString(s)
{
    s := StrReplace(s, "\", "\\")
    s := StrReplace(s, '"', '\"')
    s := StrReplace(s, "`n", "\n")
    s := StrReplace(s, "`r", "\r")
    s := StrReplace(s, "`t", "\t")
    if RegExMatch(s, "[\x00-\x08\x0B\x0C\x0E-\x1F]")
        s := RegExReplace(s, "[\x00-\x08\x0B\x0C\x0E-\x1F]", "")
    return '"' s '"'
}
