using System.Text;
using System.Text.RegularExpressions;
using LibBundle3;
using LibBundle3.Nodes;
using Index = LibBundle3.Index;

namespace PoeDataExtract.Extractors;

/// <summary>
/// Extracts <c>data/unique_item_name_map.tsv</c> — Metadata path → unique
/// item display name. PoE2 has no `UniqueItems` table; the mapping is
/// reconstructed by joining four DAT tables, with
/// <c>ItemVisualIdentity</c> bridging two disjoint FK spaces:
///
///   <list type="bullet">
///     <item><c>BaseItemTypes.ItemVisualIdentity</c> → references the
///           base item's regular icon-IVI (e.g. row 7800).</item>
///     <item><c>UniqueStashLayout.ItemVisualIdentityKey</c> → references
///           the unique's own art-IVI (e.g. row 14972 for Kaom's Heart).</item>
///   </list>
///
/// The two IVI rows live in the SAME ItemVisualIdentity table but are
/// distinct rows — base IVIs and unique IVIs don't share a row index.
/// What they DO share is a structurally-similar
/// <see cref="ItemVisualIdentity"/>.Id string: e.g. base
/// <c>"BodyArmourDexBase4"</c> vs unique <c>"BodyArmourDexUnique4"</c>.
/// The fuzzy match key (token-split + sort + drop the "Four"/"Unique"
/// distinguishers) normalises both to the same key, so we can join.
///
/// Reference implementation: Tools/build_item_names_csv.py. The
/// non-CSV variant explore_unique_names.py was exploratory and never
/// implemented this last step — direct FK matching on IVI keys
/// returned 0 results.
///
/// Schema offsets (dat-schema, validFor=2):
///   Words:                @0  Wordlist (enumrow=i32)
///                         @4  Text     (string)
///   UniqueStashLayout:    @0  WordsKey               (foreignrow → Words)
///                         @16 ItemVisualIdentityKey  (foreignrow → ItemVisualIdentity)
///   ItemVisualIdentity:   @0  Id                     (string)
///   BaseItemTypes:        @0   Id                    (string)
///                         @124 ItemVisualIdentity    (foreignrow → ItemVisualIdentity)
/// </summary>
internal sealed class UniqueNames : IExtractor
{
    private const int OFF_WORDS_WORDLIST = 0;
    private const int OFF_WORDS_TEXT     = 4;
    private const int WORDLIST_UNIQUES   = 6;

    private const int OFF_USL_WORDS_KEY  = 0;
    private const int OFF_USL_IVI_KEY    = 16;

    private const int OFF_IVI_ID         = 0;

    private const int OFF_BIT_ID         = 0;
    private const int OFF_BIT_IVI        = 124;

    // CamelCase token + digit-group splitter. Mirrors the Python regex
    // [A-Z][a-z0-9]*|[0-9]+ — captures either a Capitalised token
    // (running until next capital or end) OR a run of digits.
    private static readonly Regex TokenRegex = new(@"[A-Z][a-z0-9]*|[0-9]+", RegexOptions.Compiled);

    public void Run(Index index, string outputTsvPath)
    {
        var words = OpenDat(index, "data/balance/words.datc64");
        var usl   = OpenDat(index, "data/balance/uniquestashlayout.datc64");
        var ivi   = OpenDat(index, "data/balance/itemvisualidentity.datc64");
        var bit   = OpenDat(index, "data/balance/baseitemtypes.datc64");
        Console.Out.WriteLine($"opened: Words rs={words.RowSize}#{words.RowCount}, "
            + $"USL rs={usl.RowSize}#{usl.RowCount}, "
            + $"IVI rs={ivi.RowSize}#{ivi.RowCount}, "
            + $"BIT rs={bit.RowSize}#{bit.RowCount}");

        // 1) Words: row → unique-name text (filtered to wordlist=6 = uniques).
        var uniqueNameByWordRow = new Dictionary<long, string>(capacity: 4096);
        for (int i = 0; i < words.RowCount; i++)
        {
            if (words.RowI32(i, OFF_WORDS_WORDLIST) != WORDLIST_UNIQUES) continue;
            string text = words.RowString(i, OFF_WORDS_TEXT);
            if (!string.IsNullOrEmpty(text)) uniqueNameByWordRow[i] = text;
        }

        // 2) ItemVisualIdentity: row → fuzzy match key derived from
        //    its Id string. Computed once for the whole table so the
        //    USL/BIT join below is just two hashmap lookups per row.
        var matchKeyByIviRow = new Dictionary<long, string>(capacity: ivi.RowCount);
        for (int i = 0; i < ivi.RowCount; i++)
        {
            string iviId = ivi.RowString(i, OFF_IVI_ID);
            if (string.IsNullOrEmpty(iviId)) continue;
            string key = IviMatchKey(iviId);
            if (key != "") matchKeyByIviRow[i] = key;
        }

        // 3) UniqueStashLayout: walk every USL row, look up its IVI
        //    match key, then list of unique names per key.
        //    Multiple uniques can share one key (RenamedVersion +
        //    BaseVersion variants, e.g. old + new Kaom's Heart art).
        var namesByMatchKey = new Dictionary<string, List<string>>(capacity: 1024);
        for (int i = 0; i < usl.RowCount; i++)
        {
            long wordsRow = usl.RowFk(i, OFF_USL_WORDS_KEY);
            long iviRow   = usl.RowFk(i, OFF_USL_IVI_KEY);
            if (wordsRow < 0 || iviRow < 0) continue;
            if (!uniqueNameByWordRow.TryGetValue(wordsRow, out var name)) continue;
            if (!matchKeyByIviRow.TryGetValue(iviRow, out var key)) continue;

            if (!namesByMatchKey.TryGetValue(key, out var list))
            {
                list = new List<string>(2);
                namesByMatchKey[key] = list;
            }
            if (!list.Contains(name)) list.Add(name);
        }
        Console.Out.WriteLine($"  built {namesByMatchKey.Count} unique match keys "
            + $"(from {uniqueNameByWordRow.Count} wordlist=6 words, "
            + $"{usl.RowCount} USL rows)");

        // 4) BaseItemTypes: emit (Metadata/... path → unique name).
        var sb = new StringBuilder(capacity: namesByMatchKey.Count * 80);
        sb.Append("# unique_item_name_map.tsv - auto-generated by ggpk-tools/PoeDataExtract\n");
        sb.Append("# source: 4-way join Words + UniqueStashLayout + ItemVisualIdentity + BaseItemTypes (.datc64)\n");
        sb.Append("# columns: metadata_path\tunique_name\n");
        sb.Append($"# generated: {DateTime.UtcNow:yyyy-MM-ddTHH:mm:ssZ}\n");

        int emitted = 0;
        for (int i = 0; i < bit.RowCount; i++)
        {
            long iviRow = bit.RowFk(i, OFF_BIT_IVI);
            if (iviRow < 0) continue;
            if (!matchKeyByIviRow.TryGetValue(iviRow, out var key)) continue;
            if (!namesByMatchKey.TryGetValue(key, out var names)) continue;
            string id = bit.RowString(i, OFF_BIT_ID);
            if (string.IsNullOrEmpty(id)) continue;
            foreach (var name in names)
            {
                string clean = name.Replace('\t', ' ').Replace('\n', ' ').Replace('\r', ' ');
                sb.Append(id).Append('\t').Append(clean).Append('\n');
                emitted++;
            }
        }

        var dir = Path.GetDirectoryName(outputTsvPath);
        if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
        string tmp = outputTsvPath + ".tmp";
        File.WriteAllText(tmp, sb.ToString(), new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));
        if (File.Exists(outputTsvPath)) File.Delete(outputTsvPath);
        File.Move(tmp, outputTsvPath);
        Console.Out.WriteLine($"wrote {emitted} rows to {outputTsvPath}");
    }

    /// <summary>
    /// Normalises an ItemVisualIdentity Id string into a stable join
    /// key so a base item's IVI Id ("BodyArmourDexBase4") and the
    /// matching unique's IVI Id ("BodyArmourDexUnique4") collapse to
    /// the same key. Algorithm (port of
    /// Tools/build_item_names_csv.py::ivi_match_key):
    ///   1) Split on CamelCase tokens OR digit-groups.
    ///   2) Pull out the first digit-group as the "num" component.
    ///   3) From the remaining tokens, drop "Four" + "Unique" — those
    ///      are the conventional base-vs-unique distinguishers and
    ///      would prevent the match.
    ///   4) Sort the rest ordinally + return "tokens|num".
    /// </summary>
    private static string IviMatchKey(string iviId)
    {
        if (string.IsNullOrEmpty(iviId)) return "";
        var matches = TokenRegex.Matches(iviId);
        if (matches.Count == 0) return "";

        string num = "";
        var rest = new List<string>(matches.Count);
        foreach (Match m in matches)
        {
            string tok = m.Value;
            if (tok.Length > 0 && char.IsDigit(tok[0]))
            {
                if (num == "") num = tok;     // keep only the FIRST digit group
                continue;
            }
            if (tok == "Four" || tok == "Unique") continue;
            rest.Add(tok);
        }
        rest.Sort(StringComparer.Ordinal);
        return string.Join(",", rest) + "|" + num;
    }

    private static DatReader OpenDat(Index index, string path)
    {
        if (!index.TryFindNode(path, out var node) || node is not FileNode file)
            throw new FileNotFoundException(path);
        return new DatReader(file.Record.Read().Span);
    }
}
