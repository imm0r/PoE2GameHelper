using System.Text;

namespace PoeDataExtract;

/// <summary>
/// Minimal reader for PoE's <c>.dat64</c> binary table format.
///
/// Layout (as of PoE2 0.x — same as PoE1's .dat64):
///   <list type="bullet">
///     <item>uint32  rowCount</item>
///     <item>rowCount × rowSize bytes (fixed-width row records)</item>
///     <item>8-byte boundary marker: 0xBBBBBBBBBBBBBBBB</item>
///     <item>variable-length "data section" — referenced from rows by
///           (length, offset) pairs for strings/arrays</item>
///   </list>
///
/// We do not infer schemas from .dat64 alone — caller passes the row
/// size + column offsets it expects. Schema discovery lives in
/// DAT-Schema mirror data baked into the individual extractors.
/// </summary>
internal sealed class DatReader
{
    private const ulong BoundaryMarker = 0xBBBBBBBBBBBBBBBB;

    public int RowCount { get; }
    public int RowSize { get; }

    private readonly byte[] _rows;     // RowCount * RowSize bytes
    private readonly byte[] _data;     // variable-section, indexed by row offsets

    /// <summary>
    /// Open a .dat64 / .datc64 file. If <paramref name="rowSize"/> is
    /// non-null, validate against the BB marker at that exact position.
    /// If null, auto-detect rowSize by scanning for the marker (at any
    /// 4-byte aligned offset after the header) and deriving
    /// <c>rowSize = (markerOffset - 4) / rowCount</c>.
    /// </summary>
    public DatReader(ReadOnlySpan<byte> file, int? rowSize = null)
    {
        if (file.Length < 4)
            throw new InvalidDataException("dat64 file too small");

        RowCount = BitConverter.ToInt32(file[..4]);
        const int headerLen = 4;

        int markerOff;
        if (rowSize is int rs)
        {
            markerOff = headerLen + RowCount * rs;
            if (markerOff + 8 > file.Length)
                throw new InvalidDataException(
                    $"dat64 truncated: header+rows+marker > file ({markerOff + 8} > {file.Length})");
            ulong marker = BitConverter.ToUInt64(file.Slice(markerOff, 8));
            if (marker != BoundaryMarker)
                throw new InvalidDataException(
                    $"boundary marker mismatch at offset 0x{markerOff:X}: got 0x{marker:X16} — wrong rowSize?");
            RowSize = rs;
        }
        else
        {
            // Scan byte-by-byte. PoE2 lets rowSize be effectively any
            // value, and with rowCount * rowSize feeding the marker
            // position we can't assume 2- or 4-byte alignment:
            //   - BaseItemTypes: rs=308 → marker 4-aligned
            //   - MonsterVarieties: rs=974 → marker 2-aligned
            //   - Stats: rs=106 → marker 2-aligned
            //   - Mods: rs is odd (14841 rows × odd → odd marker offset)
            // step=1 over 12 MB is still <20 ms in practice (one ulong
            // compare per iteration), and runs once per refresh.
            int? found = null;
            for (int off = headerLen; off + 8 <= file.Length; off += 1)
            {
                if (BitConverter.ToUInt64(file.Slice(off, 8)) == BoundaryMarker)
                {
                    int candidateLen = off - headerLen;
                    if (RowCount > 0 && candidateLen % RowCount == 0)
                    {
                        found = off;
                        break;
                    }
                }
            }
            if (found is null)
                throw new InvalidDataException("no 0xBB boundary marker found anywhere in file");
            markerOff = found.Value;
            RowSize = (markerOff - headerLen) / RowCount;
        }

        _rows = file.Slice(headerLen, markerOff - headerLen).ToArray();
        _data = file[(markerOff + 8)..].ToArray();
    }

    public ReadOnlySpan<byte> Row(int index)
    {
        if ((uint)index >= (uint)RowCount)
            throw new ArgumentOutOfRangeException(nameof(index));
        return _rows.AsSpan(index * RowSize, RowSize);
    }

    /// <summary>Read a little-endian int32 at the given offset inside row.</summary>
    public int RowI32(int index, int offset) =>
        BitConverter.ToInt32(Row(index)[offset..(offset + 4)]);

    /// <summary>
    /// Read a variable-length array column. PoE encodes arrays as a
    /// 16-byte (count: u64, dataOffset: u64) pair in the row; the
    /// actual element data lives in the data section at
    /// <c>dataOffset</c>. Unlike string refs, array offsets are NOT
    /// biased — they point straight at the first element byte.
    ///
    /// This helper returns the elements as <c>long[]</c>, reading
    /// <paramref name="elementBytes"/> bytes per element (typical
    /// values: 8 for plain `array` of row-indices, 16 for
    /// `foreignrow[]` — in the latter case the second 8 bytes hold
    /// the table identifier and are ignored, matching the convention
    /// in <see cref="RowFk"/>).
    ///
    /// Returns an empty array for null/sentinel/out-of-range refs.
    /// </summary>
    public long[] RowArray(int index, int offset, int elementBytes)
    {
        var rowSpan = Row(index);
        ulong count = BitConverter.ToUInt64(rowSpan[offset..(offset + 8)]);
        ulong ptr   = BitConverter.ToUInt64(rowSpan[(offset + 8)..(offset + 16)]);
        // Sanity: 0/sentinel/absurd → empty. 4096 is comfortably above
        // any real PoE array length we've seen.
        if (count == 0 || count > 4096) return Array.Empty<long>();
        long byteStart = (long)ptr;
        long byteEnd = byteStart + (long)count * elementBytes;
        if (byteStart < 0 || byteEnd > _data.Length) return Array.Empty<long>();
        var result = new long[count];
        for (int i = 0; i < (int)count; i++)
        {
            long elemAt = byteStart + (long)i * elementBytes;
            ulong raw = BitConverter.ToUInt64(_data.AsSpan((int)elemAt, 8));
            // Same null-sentinel handling as RowFk.
            if (raw == 0xFFFFFFFFFFFFFFFFUL || raw == 0xFEFEFEFEFEFEFEFEUL
                || raw > (ulong)int.MaxValue)
                result[i] = -1;
            else
                result[i] = (long)raw;
        }
        return result;
    }

    /// <summary>
    /// Read a foreign-key row index from inside a row. PoE schema types
    /// `row` (8 bytes) and `foreignrow` (16 bytes, second half is
    /// usually a table identifier or unused) both encode the target
    /// row as a u64 starting at <paramref name="offset"/> — we read
    /// only that first u64. Returns -1 for null sentinels (FE-pattern
    /// or all-FF, which PoE uses to mean "no reference"), otherwise
    /// the row index. Callers should bounds-check the result against
    /// the target table's RowCount.
    /// </summary>
    public long RowFk(int index, int offset)
    {
        ulong raw = BitConverter.ToUInt64(Row(index)[offset..(offset + 8)]);
        // 0xFFFF...FFFF and 0xFEFE...FEFE both show up in practice as
        // "no foreign key set"; treat both as invalid.
        if (raw == 0xFFFFFFFFFFFFFFFFUL || raw == 0xFEFEFEFEFEFEFEFEUL)
            return -1;
        // Anything above ~10M rows is clearly nonsense too — let the
        // caller catch out-of-range against the real row count, but
        // defend against signed-overflow weirdness by capping here.
        if (raw > (ulong)int.MaxValue)
            return -1;
        return (long)raw;
    }

    /// <summary>
    /// Read a string ref (int64) and decode the target as a UTF-16
    /// zero-terminated string.
    ///
    /// PoE1 .dat64 reserved the first 8 bytes of the data section as a
    /// "null/empty" sentinel — actual strings lived at offset 8 onwards
    /// and refs were absolute byte offsets. PoE2 .datc64 packs the
    /// first real string immediately at byte 0, but KEPT the original
    /// ref encoding: <c>ref = actual_byte_offset + 8</c>. So we
    /// subtract 8 here to land on string content.
    /// Special values:
    ///   <list type="bullet">
    ///     <item><c>ref == 0</c>  → null/empty string (returns "")</item>
    ///     <item><c>ref &lt; 0</c> (e.g. 0xFEFEFEFEFEFEFEFE) → null sentinel</item>
    ///   </list>
    /// </summary>
    public string RowString(int index, int offset)
    {
        long dataOff = BitConverter.ToInt64(Row(index)[offset..(offset + 8)]);
        if (dataOff <= 0) return "";        // 0 = null/empty; negative = FE sentinel
        long actualOff = dataOff - 8;       // strip the legacy-sentinel 8-byte bias
        if (actualOff < 0 || actualOff + 2 > _data.Length) return "";
        // Find UTF-16 null terminator.
        int end = (int)actualOff;
        while (end + 1 < _data.Length && !(_data[end] == 0 && _data[end + 1] == 0))
            end += 2;
        return Encoding.Unicode.GetString(_data, (int)actualOff, end - (int)actualOff);
    }
}
