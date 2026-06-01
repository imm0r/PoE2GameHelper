using System.Text;
using LibBundle3;
using Index = LibBundle3.Index;
using LibBundle3.Nodes;

namespace PoeDataExtract;

/// <summary>
/// Schema-less .dat64 dumper. Used to figure out (or sanity-check) row
/// size + column offsets after a GGG patch.
///
/// Strategy:
///   <list type="number">
///     <item>Read row count from first 4 bytes.</item>
///     <item>Scan forward for the 0xBBBBBBBBBBBBBBBB boundary marker
///           (8-byte aligned). The first one we hit is the real marker —
///           the byte pattern is rare enough in genuine row data that
///           false positives are unlikely.</item>
///     <item>rowSize = (markerOffset - 4) / rowCount. If non-integer
///           the file is malformed (or the marker is a false positive,
///           though we keep scanning in that case).</item>
///     <item>Hex-dump the first three rows, side-by-side per column, so
///           shared offsets pop visually. Dump first ~512 bytes of the
///           data section as UTF-16 + UTF-8 for string column ID-ing.</item>
///   </list>
/// </summary>
internal static class DatInspector
{
    private const ulong BoundaryMarker = 0xBBBBBBBBBBBBBBBB;

    public static void Inspect(Index index, string table, TextWriter w)
    {
        // PoE1 layout: "Data/<Name>.dat64"
        // PoE2 layout: "data/balance/<name>.datc64"  (lowercase, moved to balance/, new ext)
        // The .datc64 byte layout is identical to .dat64 — the 'c' is
        // not a compression marker (verified: FEFEFEFEFEFEFEFE null
        // sentinels present, no Oodle magic, marker still 0xBB).
        string lower = table.ToLowerInvariant();
        string[] candidates = { $"Data/{table}.dat64", $"data/balance/{lower}.datc64" };
        FileNode? fileNode = null;
        string? path = null;
        foreach (var c in candidates)
        {
            if (index.TryFindNode(c, out var node) && node is FileNode fn) { fileNode = fn; path = c; break; }
        }
        if (fileNode is null)
            throw new FileNotFoundException($"None of: {string.Join(", ", candidates)}");

        var bytes = fileNode.Record.Read().Span;
        w.WriteLine($"== {path} ==");
        w.WriteLine($"file size: {bytes.Length} bytes");

        if (bytes.Length < 12) { w.WriteLine("file too small"); return; }
        int rowCount = BitConverter.ToInt32(bytes[..4]);
        w.WriteLine($"rowCount  : {rowCount}");

        // Standard .dat64 marker is 0xBBBBBBBBBBBBBBBB. PoE2 .datc64
        // may use something else — scan for any 8-byte-aligned run of
        // identical bytes and report the candidates so we can ID the
        // new marker visually.
        int? markerOff = FindMarker(bytes, 0xBB);
        if (markerOff is null)
        {
            w.WriteLine("no 0xBB marker — scanning for other 8-byte sentinels...");
            var runs = FindRepeatedByteRuns(bytes, minRunLen: 8);
            foreach (var (off, b, len) in runs.Take(20))
                w.WriteLine($"  candidate marker @0x{off:X8}  byte=0x{b:X2}  run={len} bytes");
            if (runs.Count == 0)
                w.WriteLine("  no repeated-byte runs of length >= 8 found anywhere — file may be compressed");
            // Hex dump first 128 bytes for visual inspection regardless.
            w.WriteLine();
            w.WriteLine("-- first 128 bytes --");
            for (int off = 0; off < Math.Min(128, bytes.Length); off += 16)
                w.WriteLine($"0x{off:X4}  {HexBytes(bytes.Slice(off, Math.Min(16, bytes.Length - off)))}");
            // Tail dump: reveals whether the data section (with strings)
            // sits at the end uncompressed, or if the whole file looks
            // like noise (= Oodle-compressed).
            w.WriteLine();
            int tail = Math.Min(256, bytes.Length);
            int tailStart = bytes.Length - tail;
            w.WriteLine($"-- last {tail} bytes (offset 0x{tailStart:X8}+) --");
            for (int off = 0; off < tail; off += 16)
            {
                int absOff = tailStart + off;
                int take = Math.Min(16, tail - off);
                var slice = bytes.Slice(absOff, take);
                w.Write($"0x{absOff:X8}  {HexBytes(slice).PadRight(48)}  ");
                // ASCII rendering — printable bytes as-is, others as '.'
                foreach (var by in slice)
                    w.Write((by >= 0x20 && by < 0x7F) ? (char)by : '.');
                w.WriteLine();
            }
            // PoE2 .datc64 has no boundary marker — data section
            // immediately follows the rows. Find data section start by
            // scanning for the first long UTF-16 ASCII run (a string
            // like "Metadata/..."). Then rowSize = (start - 4) / rowCount.
            w.WriteLine();
            w.WriteLine("-- data-section-start heuristic --");
            int? firstStr = FindFirstUtf16Run(bytes, minChars: 12);
            if (firstStr is null)
            {
                w.WriteLine("  no UTF-16 ASCII run >= 12 chars found — heuristic failed");
                return;
            }
            w.WriteLine($"  first long UTF-16 string @0x{firstStr:X8}");
            // The data section typically begins with 8 zero bytes (the
            // null/empty string at offset 0). Walk backwards from the
            // first string to find the section header.
            // Estimate rowSize from where the first string lives, then
            // search nearby integer values for the one that produces the
            // most valid string-ref columns. The actual data section may
            // start anywhere in the "zero pad" preceding the first
            // string, so we don't trust the walk-back exactly.
            double estimate = (double)(firstStr.Value - 4) / rowCount;
            w.WriteLine($"  estimated rowSize ≈ {estimate:F3} (from first-string offset)");
            int bestRs = -1, bestScore = -1, bestSectionStart = -1;
            // Show scores for all candidates in window, not just winner.
            // Hard filter: sectionStart must begin with >= 4 zero bytes
            // (the canonical empty/null-string sentinel at the start of
            // a data section). Without this filter, "rs" values that
            // land sectionStart inside a string get inflated scores.
            w.WriteLine("  rowSize  sectionStart  zeroPad  score");
            for (int rs = Math.Max(8, (int)estimate - 10); rs <= (int)estimate + 10; rs++)
            {
                long ss = 4L + (long)rowCount * rs;
                if (ss < 0 || ss + 8 > bytes.Length) continue;
                int zeroPad = 0;
                while (zeroPad < 16 && ss + zeroPad < bytes.Length && bytes[(int)ss + zeroPad] == 0) zeroPad++;
                int score = ScoreRowSize(bytes, rs, rowCount, (int)ss, samples: 50);
                w.WriteLine($"  {rs,7}  0x{ss:X8}    {zeroPad,2}      {score}");
                if (zeroPad < 4) continue;  // hard reject mid-string starts
                if (score > bestScore) { bestScore = score; bestRs = rs; bestSectionStart = (int)ss; }
            }
            w.WriteLine($"  ⇒ winner rs={bestRs}");
            // Also dump bytes around firstStr to see EXACTLY what the
            // data section boundary looks like.
            w.WriteLine();
            w.WriteLine($"-- 80 bytes around firstStr=0x{firstStr:X8} (-32 .. +48) --");
            int aroundStart = Math.Max(0, firstStr.Value - 32);
            int aroundEnd = Math.Min(firstStr.Value + 48, bytes.Length);
            for (int off = aroundStart; off < aroundEnd; off += 16)
            {
                int take = Math.Min(16, aroundEnd - off);
                var slice = bytes.Slice(off, take);
                w.Write($"0x{off:X8}  {HexBytes(slice).PadRight(48)}  ");
                foreach (var by in slice)
                    w.Write((by >= 0x20 && by < 0x7F) ? (char)by : '.');
                w.WriteLine();
            }
            // Test the "header=12" hypothesis directly:
            // PoE2 .datc64 may have an 8-byte header AFTER rowCount,
            // making the effective layout: [u32 rowCount][8 bytes hdr][rows][data].
            w.WriteLine();
            int h12rs = 308;
            long h12ss = 12L + (long)rowCount * h12rs;
            w.WriteLine($"-- hypothesis: header=12, rs={h12rs} → sectionStart=0x{h12ss:X8}");
            if (h12ss == firstStr.Value)
                w.WriteLine($"   ✓ exact match with firstStr position!");
            // Dump 256 bytes at the inferred sectionStart so we can see
            // what the data section actually starts with.
            w.WriteLine();
            w.WriteLine($"-- 256 bytes at scoring-winner sectionStart=0x{bestSectionStart:X8} --");
            int dumpEnd = Math.Min(bestSectionStart + 256, bytes.Length);
            for (int off = bestSectionStart; off < dumpEnd; off += 16)
            {
                int take = Math.Min(16, dumpEnd - off);
                var slice = bytes.Slice(off, take);
                w.Write($"0x{off:X8}  {HexBytes(slice).PadRight(48)}  ");
                foreach (var by in slice)
                    w.Write((by >= 0x20 && by < 0x7F) ? (char)by : '.');
                w.WriteLine();
            }
            int sectionStart = bestSectionStart;
            int rowsBytes = sectionStart - 4;
            if (bestRs > 0 && rowsBytes > 0 && rowsBytes % rowCount == 0)
            {
                int rs = bestRs;
                w.WriteLine($"  ⇒ rowSize = {rs} bytes  (rowCount={rowCount}, total rows bytes={rowsBytes})");
                // Verify by dumping a couple of rows side-by-side.
                int show = Math.Min(3, rowCount);
                w.WriteLine();
                w.WriteLine($"-- first {show} rows with inferred rowSize={rs} --");
                w.WriteLine("offset   " + string.Join("  ", Enumerable.Range(0, show).Select(i => $"row{i,-46}")));
                for (int off = 0; off < rs; off += 16)
                {
                    var sb = new StringBuilder();
                    sb.Append($"0x{off:X4}   ");
                    for (int r = 0; r < show; r++)
                    {
                        int rowStart = 4 + r * rs;
                        int take = Math.Min(16, rs - off);
                        if (rowStart + off + take > bytes.Length) break;
                        var slice = bytes.Slice(rowStart + off, take);
                        sb.Append(HexBytes(slice).PadRight(48)).Append("  ");
                    }
                    w.WriteLine(sb.ToString());
                }
                // Candidate string-ref scan, like the working path.
                w.WriteLine();
                w.WriteLine("-- candidate string-ref columns (offsets where row value → readable text in data section) --");
                for (int r = 0; r < show; r++)
                {
                    int rowStart = 4 + r * rs;
                    w.Write($"row{r}: ");
                    for (int off = 0; off + 8 <= rs; off += 8)
                    {
                        long dataOff = BitConverter.ToInt64(bytes.Slice(rowStart + off, 8));
                        long abs = sectionStart + dataOff;
                        if (dataOff < 0 || abs + 2 > bytes.Length) continue;
                        if (bytes[(int)abs + 1] == 0 && bytes[(int)abs] >= 0x20 && bytes[(int)abs] < 0x7F)
                        {
                            string preview = ReadU16Until(bytes, (int)abs, max: 50);
                            w.Write($"@0x{off:X3}=\"{preview}\"  ");
                        }
                    }
                    w.WriteLine();
                }
            }
            else
            {
                w.WriteLine($"  ⚠ rowsBytes not divisible by rowCount={rowCount} — heuristic missed by a few bytes");
                // Show candidate rowSizes near the estimated value
                double estimated = (double)rowsBytes / rowCount;
                w.WriteLine($"  estimated rowSize ≈ {estimated:F2}; try nearby integer values");
            }
            return;
        }
        w.WriteLine($"marker @  : 0x{markerOff:X8} ({markerOff})");

        int rowsLen = markerOff.Value - 4;
        if (rowCount <= 0) { w.WriteLine("rowCount <= 0"); return; }
        if (rowsLen % rowCount != 0)
        {
            w.WriteLine($"rowsLen({rowsLen}) not divisible by rowCount({rowCount}) — schema unstable");
            return;
        }
        int rowSize = rowsLen / rowCount;
        w.WriteLine($"rowSize   : {rowSize} bytes");
        w.WriteLine();

        // Side-by-side hex dump of first N rows, 16 bytes per line, with
        // the byte offset on the left. Reading the same offset across
        // rows tells you which columns are constant (e.g. flag bits)
        // and which vary (e.g. string refs into the data section).
        int rowsToShow = Math.Min(3, rowCount);
        w.WriteLine($"-- first {rowsToShow} rows, 16 bytes per line --");
        w.WriteLine("offset    " + string.Join("  ", Enumerable.Range(0, rowsToShow).Select(i => $"row{i,-46}")));
        for (int off = 0; off < rowSize; off += 16)
        {
            var sb = new StringBuilder();
            sb.Append($"0x{off:X4}    ");
            for (int r = 0; r < rowsToShow; r++)
            {
                int rowStart = 4 + r * rowSize;
                int take = Math.Min(16, rowSize - off);
                var slice = bytes.Slice(rowStart + off, take);
                sb.Append(HexBytes(slice).PadRight(48)).Append("  ");
            }
            w.WriteLine(sb.ToString());
        }
        w.WriteLine();

        // Data section dump — first ~512 bytes after the marker.
        int dataStart = markerOff.Value + 8;
        int dataPreview = Math.Min(512, bytes.Length - dataStart);
        w.WriteLine($"-- data section (first {dataPreview} bytes) --");
        var dataSlice = bytes.Slice(dataStart, dataPreview);

        // UTF-16 LE is the typical encoding for PoE strings. Replace
        // non-printable code units with '.' so the dump stays readable.
        var u16 = Encoding.Unicode.GetString(dataSlice);
        w.WriteLine("UTF-16: " + Printable(u16));

        // UTF-8 dump as a fallback — newer columns sometimes use it.
        var u8 = Encoding.UTF8.GetString(dataSlice);
        w.WriteLine("UTF-8 : " + Printable(u8));

        // For each row, show where its string-ref columns (if any) point.
        // We don't know the schema yet, so this is heuristic: for every
        // 8-byte aligned position in the row, treat the value as a
        // potential int64 offset and report which ones land inside the
        // data section AND look like UTF-16 text.
        w.WriteLine();
        w.WriteLine("-- candidate string-ref columns (offsets where row data → data section text) --");
        for (int r = 0; r < rowsToShow; r++)
        {
            int rowStart = 4 + r * rowSize;
            w.Write($"row{r}: ");
            for (int off = 0; off + 8 <= rowSize; off += 8)
            {
                long dataOff = BitConverter.ToInt64(bytes.Slice(rowStart + off, 8));
                if (dataOff < 0 || dataOff >= bytes.Length - dataStart) continue;
                int abs = dataStart + (int)dataOff;
                if (abs + 2 > bytes.Length) continue;
                // Heuristic: UTF-16 ASCII text → bytes[abs+1] == 0 and bytes[abs] in [0x20..0x7E]
                if (bytes[abs + 1] == 0 && bytes[abs] >= 0x20 && bytes[abs] < 0x7F)
                {
                    string preview = ReadU16Until(bytes, abs, max: 40);
                    w.Write($"@0x{off:X3}=\"{preview}\"  ");
                }
            }
            w.WriteLine();
        }
    }

    /// <summary>
    /// Validates a rowSize hypothesis: for the first N rows, count how
    /// many 8-byte-aligned int64 values look like valid string refs
    /// pointing at readable UTF-16 ASCII inside the data section. The
    /// correct rowSize will produce many hits; wrong ones, almost none.
    /// </summary>
    private static int ScoreRowSize(ReadOnlySpan<byte> bytes, int rs, int rowCount, int sectionStart, int samples)
    {
        int sampleRows = Math.Min(samples, rowCount);
        int hits = 0;
        for (int r = 0; r < sampleRows; r++)
        {
            int rowStart = 4 + r * rs;
            if (rowStart + rs > bytes.Length) break;
            for (int off = 0; off + 8 <= rs; off += 8)
            {
                long dataOff = BitConverter.ToInt64(bytes.Slice(rowStart + off, 8));
                if (dataOff < 0 || dataOff > bytes.Length - sectionStart) continue;
                long abs = sectionStart + dataOff;
                if (abs + 4 > bytes.Length) continue;
                // Require the candidate ref to point at a STRING START,
                // i.e. the 2 bytes immediately before must be the null
                // terminator (00 00) or be outside the data section.
                // This rejects refs that land mid-string (which inflated
                // the score for too-large rowSize candidates because the
                // "extra" rows were actually strings).
                if (abs - 2 >= sectionStart)
                {
                    if (bytes[(int)abs - 1] != 0 || bytes[(int)abs - 2] != 0) continue;
                }
                // The string starts with at least two UTF-16 ASCII chars.
                if (bytes[(int)abs + 1] == 0 && bytes[(int)abs] >= 0x20 && bytes[(int)abs] < 0x7F &&
                    bytes[(int)abs + 3] == 0 && bytes[(int)abs + 2] >= 0x20 && bytes[(int)abs + 2] < 0x7F)
                    hits++;
            }
        }
        return hits;
    }

    /// <summary>
    /// Finds the first offset where there's a run of UTF-16-LE ASCII
    /// characters (low byte 0x20..0x7E, high byte 0x00) of at least
    /// <paramref name="minChars"/> characters. Used to locate the data
    /// section start in .datc64 files which dropped the boundary marker.
    /// </summary>
    private static int? FindFirstUtf16Run(ReadOnlySpan<byte> bytes, int minChars)
    {
        for (int off = 4; off + minChars * 2 <= bytes.Length; off += 2)
        {
            bool ok = true;
            for (int k = 0; k < minChars; k++)
            {
                byte lo = bytes[off + k * 2];
                byte hi = bytes[off + k * 2 + 1];
                if (hi != 0 || lo < 0x20 || lo >= 0x7F) { ok = false; break; }
            }
            if (ok) return off;
        }
        return null;
    }

    private static int? FindMarker(ReadOnlySpan<byte> bytes, byte sentinelByte)
    {
        // step=1 — PoE2's rs may be odd (Mods table) so the marker
        // can land at any byte offset. See DatReader.cs for the same
        // change + table-by-table alignment notes.
        ulong needle = (ulong)sentinelByte * 0x0101010101010101UL;
        for (int off = 4; off + 8 <= bytes.Length; off++)
        {
            if (BitConverter.ToUInt64(bytes.Slice(off, 8)) == needle)
                return off;
        }
        return null;
    }

    /// <summary>
    /// Scans for sentinel-style runs: 8+ consecutive identical bytes,
    /// aligned to 8-byte boundaries (where a DAT boundary marker would
    /// land). Returns (offset, byteValue, runLength).
    /// </summary>
    private static List<(int off, byte b, int len)> FindRepeatedByteRuns(ReadOnlySpan<byte> bytes, int minRunLen)
    {
        var hits = new List<(int, byte, int)>();
        for (int off = 4; off + minRunLen <= bytes.Length; off += 8)
        {
            byte b = bytes[off];
            int len = 1;
            while (off + len < bytes.Length && bytes[off + len] == b) len++;
            if (len >= minRunLen)
            {
                hits.Add((off, b, len));
                // Skip past the run so we don't report overlapping hits.
                off += (len / 8) * 8;
            }
        }
        return hits;
    }

    private static string HexBytes(ReadOnlySpan<byte> s)
    {
        var sb = new StringBuilder(s.Length * 3);
        for (int i = 0; i < s.Length; i++) sb.Append(s[i].ToString("X2")).Append(' ');
        return sb.ToString().TrimEnd();
    }

    private static string Printable(string s)
    {
        var sb = new StringBuilder(s.Length);
        foreach (var c in s)
            sb.Append((c >= 0x20 && c < 0x7F) || c is '\n' or '\t' ? c : '.');
        return sb.ToString();
    }

    private static string ReadU16Until(ReadOnlySpan<byte> bytes, int abs, int max)
    {
        var sb = new StringBuilder();
        for (int i = 0; i < max; i++)
        {
            int p = abs + i * 2;
            if (p + 1 >= bytes.Length) break;
            byte lo = bytes[p], hi = bytes[p + 1];
            if (lo == 0 && hi == 0) break;
            if (hi == 0 && lo >= 0x20 && lo < 0x7F) sb.Append((char)lo);
            else { sb.Append('?'); break; }
        }
        return sb.ToString();
    }
}
