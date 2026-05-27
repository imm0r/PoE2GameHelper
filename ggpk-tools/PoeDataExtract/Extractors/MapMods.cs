using System.Text;
using LibBundle3;
using LibBundle3.Nodes;
using Index = LibBundle3.Index;

namespace PoeDataExtract.Extractors;

/// <summary>
/// Extracts the subset of <c>data/balance/mods.datc64</c> whose
/// <c>Domain == AREA (5)</c> — i.e. every affix the game can roll on
/// a map/area instance. Joins against <c>stats.datc64</c> for stat ids
/// and optionally against <c>data/stat_desc_map.tsv</c> (passed via
/// <c>--stat-desc-map</c>) to render the in-game tooltip text per mod.
/// Writes <c>data/map_mod_list.tsv</c>:
///
/// <code>
/// mod_id   affix_name   gen_type   mod_family   level   stat_ids   stat_values   tooltip
/// </code>
///
/// PoE2 0.x Mods row layout (verified against dat-schema <c>_Core.gql</c>
/// and the existing <see cref="Mods"/> extractor's anchor offsets):
///
/// <code>
/// @0x00  string-ref       Id              ("MapBlockChance1", …)
/// @0x08  u16              HASH16
/// @0x0A  foreignrow(16)   ModTypeKey      (single — 16 bytes: i64 rid + i64 tableId)
/// @0x1A  i32              Level           — minimum area level the mod can roll on
/// @0x1E  foreignrow(16)   StatsKey1
/// @0x2E  foreignrow(16)   StatsKey2
/// @0x3E  foreignrow(16)   StatsKey3
/// @0x4E  foreignrow(16)   StatsKey4
/// @0x5E  i32 enumrow      Domain          ← the filter column
/// @0x62  string-ref       Name            (matches Mods.OFF_MODS_NAME)
/// @0x6A  i32 enumrow      GenerationType  (matches Mods.OFF_MODS_GEN_TYPE)
/// @0x6E  foreignrow[]     Families        (matches Mods.OFF_MODS_FAMILIES)
/// @0x7E  i32              Stat1Min        ← roll-range start, per stat
/// @0x82  i32              Stat1Max        ← roll-range end
/// @0x86  i32              Stat2Min
/// @0x8A  i32              Stat2Max
/// @0x8E  i32              Stat3Min
/// @0x92  i32              Stat3Max
/// @0x96  i32              Stat4Min
/// @0x9A  i32              Stat4Max
/// </code>
///
/// Stats row layout (from <see cref="StatNames"/>):
///   @0x00 string-ref → stat id (e.g. "base_map_pack_size_percent_increase")
///
/// stat_desc_map.tsv format (legacy Python pipeline, parsed lenient):
///   stat_id \t template \t arg_index \t group_ids
///   template uses {0} {1} placeholders for stat values.
///
/// Tooltip rendering caveat (v1): for multi-stat templates that share
/// a `group_ids` row (e.g. "Adds {0} to {1} Cold Damage"), we currently
/// render each contributing stat's template independently — so the
/// result can carry a duplicate line. Single-stat templates (the vast
/// majority of map mods) render cleanly.
/// </summary>
internal sealed class MapMods : IExtractor
{
    // Mods columns (offsets match Mods.cs where they overlap)
    private const int OFF_MODS_ID         = 0x00;
    private const int OFF_MODS_LEVEL      = 0x1A;
    private const int OFF_MODS_STATKEY1   = 0x1E;
    private const int OFF_MODS_STATKEY2   = 0x2E;
    private const int OFF_MODS_STATKEY3   = 0x3E;
    private const int OFF_MODS_STATKEY4   = 0x4E;
    private const int OFF_MODS_DOMAIN     = 0x5E;
    private const int OFF_MODS_NAME       = 0x62;
    private const int OFF_MODS_GEN_TYPE   = 0x6A;
    private const int OFF_MODS_FAMILIES   = 0x6E;
    private const int OFF_MODS_STAT1MIN   = 0x7E;
    private const int OFF_MODS_STAT1MAX   = 0x82;
    private const int OFF_MODS_STAT2MIN   = 0x86;
    private const int OFF_MODS_STAT2MAX   = 0x8A;
    private const int OFF_MODS_STAT3MIN   = 0x8E;
    private const int OFF_MODS_STAT3MAX   = 0x92;
    private const int OFF_MODS_STAT4MIN   = 0x96;
    private const int OFF_MODS_STAT4MAX   = 0x9A;

    // ModFamily columns
    private const int OFF_MODFAMILY_ID    = 0x00;

    // Stats columns
    private const int OFF_STATS_ID        = 0x00;

    // We default to AREA (5) but expose the domain via the property so
    // a future caller / CLI flag can override (e.g. ATLAS=11 for map-
    // device-style mods, or FLASK=2 for utility-flask mods).
    public int DomainFilter { get; set; } = 5;

    /// <summary>
    /// Optional path to <c>data/stat_desc_map.tsv</c>. When provided,
    /// the extractor renders a `tooltip` column with the in-game-style
    /// description text. When omitted (or unreadable), the column is
    /// emitted blank — the stat_ids + stat_values columns are still
    /// populated so the caller can do the lookup themselves later.
    /// </summary>
    public string? StatDescMapPath { get; set; }

    public void Run(Index index, string outputTsvPath)
    {
        var mods      = OpenDat(index, "data/balance/mods.datc64");
        var modFamily = OpenDat(index, "data/balance/modfamily.datc64");
        var stats     = OpenDat(index, "data/balance/stats.datc64");
        Console.Out.WriteLine($"opened: Mods rs={mods.RowSize}#{mods.RowCount}, "
            + $"ModFamily rs={modFamily.RowSize}#{modFamily.RowCount}, "
            + $"Stats rs={stats.RowSize}#{stats.RowCount}");

        // ModFamily row → Id string. Same logic as Mods extractor.
        var familyIdByRow = new Dictionary<long, string>(modFamily.RowCount);
        for (int i = 0; i < modFamily.RowCount; i++)
        {
            string fid = modFamily.RowString(i, OFF_MODFAMILY_ID);
            if (!string.IsNullOrEmpty(fid)) familyIdByRow[i] = fid;
        }
        Console.Out.WriteLine($"  built family map for {familyIdByRow.Count}/{modFamily.RowCount} ModFamily rows");

        // Stats row → stat_id string. The Mods table's StatsKey foreignrows
        // hold row indices into this table; we want the string id for the
        // template lookup.
        var statIdByRow = new Dictionary<long, string>(stats.RowCount);
        for (int i = 0; i < stats.RowCount; i++)
        {
            string sid = stats.RowString(i, OFF_STATS_ID);
            if (!string.IsNullOrEmpty(sid)) statIdByRow[i] = sid;
        }
        Console.Out.WriteLine($"  built stat map for {statIdByRow.Count}/{stats.RowCount} Stats rows");

        // Optional stat_id → template lookup (from the existing Python-
        // generated stat_desc_map.tsv).
        var templates = LoadStatDescriptions(StatDescMapPath);
        if (templates is not null)
            Console.Out.WriteLine($"  loaded {templates.Count} description templates from {StatDescMapPath}");
        else if (!string.IsNullOrEmpty(StatDescMapPath))
            Console.Out.WriteLine($"  WARN: --stat-desc-map={StatDescMapPath} unreadable, tooltip column will be blank");

        // Diagnostic: print a histogram of Domain values across all mod
        // rows. Helps verify the offset is right AND confirms which
        // bucket the filter is pulling from.
        var domainHist = new Dictionary<int, int>();
        for (int i = 0; i < mods.RowCount; i++)
        {
            int d = mods.RowI32(i, OFF_MODS_DOMAIN);
            domainHist.TryGetValue(d, out int n);
            domainHist[d] = n + 1;
        }
        Console.Out.WriteLine("  Domain histogram (top 10 by frequency):");
        foreach (var kvp in domainHist.OrderByDescending(kv => kv.Value).Take(10))
            Console.Out.WriteLine($"    Domain={kvp.Key,3}  rows={kvp.Value}");

        var sb = new StringBuilder(capacity: 256 * 1024);
        sb.Append("# map_mod_list.tsv - auto-generated by ggpk-tools/PoeDataExtract\n");
        sb.Append($"# source: data/balance/mods.datc64 filtered by Domain == {DomainFilter} (AREA)\n");
        sb.Append("# columns: mod_id\taffix_name\tgen_type\tmod_family\tlevel\tstat_ids\tstat_values\ttooltip\n");
        sb.Append($"# generated: {DateTime.UtcNow:yyyy-MM-ddTHH:mm:ssZ}\n");

        int written = 0, withTooltip = 0;
        for (int i = 0; i < mods.RowCount; i++)
        {
            int domain = mods.RowI32(i, OFF_MODS_DOMAIN);
            if (domain != DomainFilter) continue;

            string id    = mods.RowString(i, OFF_MODS_ID);
            string name  = mods.RowString(i, OFF_MODS_NAME);
            int    gen   = mods.RowI32(i, OFF_MODS_GEN_TYPE);
            int    level = mods.RowI32(i, OFF_MODS_LEVEL);
            if (string.IsNullOrEmpty(id)) continue;

            name = SanitiseForTsv(name);

            // ModFamily[0] → family id (affix-exclusion group)
            string familyId = "";
            var families = mods.RowArray(i, OFF_MODS_FAMILIES, 16);
            foreach (var famRow in families)
            {
                if (famRow < 0) continue;
                if (!familyIdByRow.TryGetValue(famRow, out var fid)) continue;
                familyId = SanitiseForTsv(fid);
                break;
            }

            // Walk the 4 stat slots. Empty (rid=-1) slots are skipped.
            var slots = new (int statKeyOff, int minOff, int maxOff)[]
            {
                (OFF_MODS_STATKEY1, OFF_MODS_STAT1MIN, OFF_MODS_STAT1MAX),
                (OFF_MODS_STATKEY2, OFF_MODS_STAT2MIN, OFF_MODS_STAT2MAX),
                (OFF_MODS_STATKEY3, OFF_MODS_STAT3MIN, OFF_MODS_STAT3MAX),
                (OFF_MODS_STATKEY4, OFF_MODS_STAT4MIN, OFF_MODS_STAT4MAX),
            };

            var statIds = new List<string>();
            var statRanges = new List<(int min, int max)>();
            foreach (var (skOff, minOff, maxOff) in slots)
            {
                long statRow = mods.RowFk(i, skOff);
                if (statRow < 0) continue;
                if (!statIdByRow.TryGetValue(statRow, out var sid)) continue;
                int vMin = mods.RowI32(i, minOff);
                int vMax = mods.RowI32(i, maxOff);
                statIds.Add(sid);
                statRanges.Add((vMin, vMax));
            }

            string statIdsCsv    = string.Join(",", statIds.Select(SanitiseForTsv));
            string statValuesCsv = string.Join(",", statRanges.Select(r =>
                r.min == r.max ? r.min.ToString()
                               : $"{r.min}..{r.max}"));

            // Render tooltip if we have templates loaded. Each stat
            // gets its own line — multi-stat compound templates are
            // documented as a v1 limitation in the type doc.
            string tooltip = "";
            if (templates is not null && statIds.Count > 0)
            {
                var lines = new List<string>();
                for (int s = 0; s < statIds.Count; s++)
                {
                    if (!templates.TryGetValue(statIds[s], out var tpl)) continue;
                    string rendered = RenderTemplate(tpl, statRanges[s]);
                    if (!string.IsNullOrEmpty(rendered)) lines.Add(rendered);
                }
                tooltip = SanitiseForTsv(string.Join(" · ", lines));
                if (!string.IsNullOrEmpty(tooltip)) withTooltip++;
            }

            // GenerationType: 1=Prefix, 2=Suffix, 3=Unique, 4..10=specials.
            string genStr = (gen >= 1 && gen <= 15) ? gen.ToString() : "";

            sb.Append(id).Append('\t').Append(name)
              .Append('\t').Append(genStr).Append('\t').Append(familyId)
              .Append('\t').Append(level)
              .Append('\t').Append(statIdsCsv)
              .Append('\t').Append(statValuesCsv)
              .Append('\t').Append(tooltip)
              .Append('\n');
            written++;
        }

        var dir = Path.GetDirectoryName(outputTsvPath);
        if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
        string tmp = outputTsvPath + ".tmp";
        File.WriteAllText(tmp, sb.ToString(), new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));
        if (File.Exists(outputTsvPath)) File.Delete(outputTsvPath);
        File.Move(tmp, outputTsvPath);
        Console.Out.WriteLine($"wrote {written} map-domain mods to {outputTsvPath} "
            + $"({withTooltip} with rendered tooltip)");
    }

    // ─────────────────────────────────────────────────────────────────
    //  stat_desc_map.tsv parsing
    // ─────────────────────────────────────────────────────────────────

    /// <summary>
    /// Best-effort stat_id → template loader. The file is the legacy
    /// Python-generated <c>data/stat_desc_map.tsv</c> with format:
    /// <c>stat_id TAB template TAB arg_index TAB group_ids</c>. We only
    /// care about templates whose arg_index is 0 (single-stat
    /// substitution); multi-arg compound templates aren't fully
    /// handled in v1.
    /// </summary>
    private static Dictionary<string, string>? LoadStatDescriptions(string? path)
    {
        if (string.IsNullOrEmpty(path)) return null;
        if (!File.Exists(path)) return null;
        var dict = new Dictionary<string, string>(StringComparer.Ordinal);
        try
        {
            foreach (var line in File.ReadLines(path))
            {
                if (line.Length == 0 || line[0] == '#') continue;
                var parts = line.Split('\t');
                if (parts.Length < 2) continue;
                string sid = parts[0];
                string tpl = parts[1];
                if (string.IsNullOrEmpty(sid) || string.IsNullOrEmpty(tpl)) continue;
                // First entry wins — duplicates can appear when the
                // Python tool emits one row per stat-id-in-group, but
                // we render per-stat so the first canonical row is
                // enough for our use case.
                if (!dict.ContainsKey(sid)) dict[sid] = tpl;
            }
            return dict;
        }
        catch
        {
            return null;
        }
    }

    /// <summary>
    /// Substitutes the rolled value range into a stat_desc template.
    /// `{0}` becomes either a single number (min==max) or a
    /// `(min-max)` range. Other `{N}` placeholders that we can't fill
    /// from this single stat get replaced with `?` so a missed
    /// multi-stat template at least renders something readable.
    /// </summary>
    private static string RenderTemplate(string template, (int min, int max) range)
    {
        string val = range.min == range.max
            ? range.min.ToString()
            : $"({range.min}-{range.max})";
        string s = template.Replace("{0}", val).Replace("{}", val);
        // Any leftover positional placeholders ({1}, {2}, …) — leave a
        // visible marker so the user can spot multi-stat templates
        // that didn't render fully.
        for (int n = 1; n <= 9; n++)
            s = s.Replace("{" + n + "}", "?");
        return s.Trim();
    }

    private static string SanitiseForTsv(string s) =>
        s is null ? "" : s.Replace('\t', ' ').Replace('\n', ' ').Replace('\r', ' ');

    private static DatReader OpenDat(Index index, string path)
    {
        if (!index.TryFindNode(path, out var node) || node is not FileNode file)
            throw new FileNotFoundException(path);
        return new DatReader(file.Record.Read().Span);
    }
}
