using PoeDataExtract.Extractors;

namespace PoeDataExtract;

/// <summary>
/// CLI entry. Invoked by the AHK host via shell-out — args in, file out,
/// exit code for success/failure. No interactive prompts, no stdin.
///
/// Verbs:
///     extract  --ggpk &lt;Content.ggpk&gt; --table &lt;Name&gt; --output &lt;out.tsv&gt;
///         Parse a known table to TSV using the extractor registered for &lt;Name&gt;.
///
///     inspect  --ggpk &lt;Content.ggpk&gt; --table &lt;Name&gt; [--output &lt;dump.txt&gt;]
///         Reverse-engineer-helper: locate the 0xBB boundary marker,
///         derive row size, hex-dump the first three rows + start of
///         the data section. Used to verify / discover column offsets
///         when a new PoE2 patch shuffles the schema.
///
/// Exit codes:
///     0  success
///     1  bad args / unknown table
///     2  GGPK could not be opened
///     3  table not found inside the GGPK / bundles
///     4  I/O failure writing output
/// </summary>
internal static class Program
{
    [STAThread] // required for the comdlg32 file picker the Oodle resolver may show
    private static int Main(string[] args)
    {
        if (args.Length == 0) { PrintUsage(); return 1; }

        // The interactive Oodle file-picker is only offered for genuine
        // manual CLI use: suppressed when --no-prompt is passed or when any
        // standard stream is redirected (the AHK shell-out redirects stderr,
        // so its automated calls never pop a dialog).
        bool allowPrompt = !HasFlag(args, "--no-prompt")
            && !Console.IsErrorRedirected && !Console.IsInputRedirected;

        string verb = args[0].ToLowerInvariant();

        try
        {
            // Convenience form: `poe-data-extract <path-to-_.index.bin|Content.ggpk>`
            // with no verb runs a full extract-all into the repo data/ folder.
            if (!IsKnownVerb(verb))
            {
                if (LooksLikePath(args[0]))
                {
                    OodleResolver.EnsureAvailable(args[0], allowPrompt);
                    return RunExtractAll(args.AsSpan());
                }
                return Fail($"Unknown verb: {verb}", 1);
            }

            // Known verb: make the Oodle native DLL available before we open
            // any bundle. Best-effort — never aborts here.
            OodleResolver.EnsureAvailable(FindGgpkHint(args), allowPrompt);

            var rest = args.AsSpan(1);
            return verb switch
            {
                "extract"     => RunExtract(rest),
                "extract-all" => RunExtractAll(rest),
                "inspect"     => RunInspect(rest),
                "ls"          => RunLs(rest),
                "cat"         => RunCat(rest),
                _ => Fail($"Unknown verb: {verb}", 1), // unreachable (IsKnownVerb)
            };
        }
        catch (ArgumentException ex)
        {
            Console.Error.WriteLine(ex.Message);
            return 1;
        }
        catch (FileNotFoundException ex)
        {
            Console.Error.WriteLine($"Required file missing inside GGPK: {ex.Message}");
            return 3;
        }
        catch (IOException ex)
        {
            Console.Error.WriteLine($"I/O failure: {ex.Message}");
            return 4;
        }
    }

    private static int RunExtract(ReadOnlySpan<string> args)
    {
        var opts = ParseArgs(args);
        if (opts is null || opts.OutputPath is null) { PrintUsage(); return 1; }
        if (!File.Exists(opts.GgpkPath)) { Console.Error.WriteLine($"GGPK not found: {opts.GgpkPath}"); return 2; }

        using var ggpk = GgpkOpener.Open(opts.GgpkPath);
        // Table names are case-insensitive — the AHK shell-out has historically
        // used PascalCase; some consumers pass snake_case. Normalise here so
        // the bridge doesn't have to care.
        IExtractor extractor = opts.Table.ToLowerInvariant() switch
        {
            "baseitemtypes"  or "baseitemsizes"      => new BaseItemSizes(),
            "monsternames"   or "monstervarieties"   => new MonsterNames(),
            "statnames"      or "stats"              => new StatNames(),
            "mods"           or "modnamemap"         => new Mods(),
            "mapmods"        or "areamods"           => new MapMods(),
            "uniquenames"    or "uniqueitemnamemap"  => new UniqueNames(),
            _ => throw new ArgumentException($"Unknown table: {opts.Table}"),
        };
        // Optional --mod-domain N override for MapMods. Lets the user
        // re-run the same extractor pointing at a different ModDomain
        // bucket (FLASK=2, ATLAS=11, HEIST_AREA=22, …) without a rebuild.
        // --stat-desc-map enables the tooltip-rendering pass against
        // the existing data/stat_desc_map.tsv.
        if (extractor is MapMods mapMods)
        {
            if (opts.ModDomain is int d) mapMods.DomainFilter = d;
            if (opts.StatDescMap is { Length: > 0 }) mapMods.StatDescMapPath = opts.StatDescMap;
        }
        extractor.Run(ggpk.Index, opts.OutputPath);
        Console.Out.WriteLine($"OK — wrote {opts.OutputPath}");
        return 0;
    }

    /// <summary>
    /// Refreshes every TSV the helper consumes in one shell-out. Opens
    /// the GGPK once and runs each extractor against it — saves the
    /// ~300 ms .NET-startup cost of invoking the tool per table.
    ///
    /// Usage: poe-data-extract extract-all [--ggpk] &lt;path&gt; [--output-dir &lt;dir&gt;]
    ///        poe-data-extract &lt;path&gt;     (bare path → same thing)
    ///
    /// The ggpk/index path may be passed positionally or via --ggpk. When
    /// --output-dir is omitted it defaults to the repo's data/ folder
    /// (see <see cref="RepoDataDir"/>), so a plain
    /// `poe-data-extract <path>` refreshes the whole data pack in place.
    ///
    /// Each extractor writes a fixed filename inside output-dir:
    ///     base_item_sizes.tsv          (BaseItemSizes — Id+Name+W+H)
    ///     monster_name_map.tsv         (MonsterNames)
    ///     stat_name_map.tsv            (StatNames)
    ///     mod_name_map.tsv             (Mods)
    ///     unique_item_name_map.tsv     (UniqueNames)
    ///     map_mod_list.tsv             (MapMods — optional; failure doesn't
    ///                                   fail the batch as it's the most
    ///                                   schema-fragile and not yet consumed)
    /// </summary>
    private static int RunExtractAll(ReadOnlySpan<string> args)
    {
        string? ggpkPath = null, outDir = null;
        for (int i = 0; i < args.Length; i++)
        {
            switch (args[i])
            {
                case "--ggpk":       if (++i < args.Length) ggpkPath = args[i]; break;
                case "--output-dir": if (++i < args.Length) outDir   = args[i]; break;
                default:
                    // Accept the first non-flag token as the ggpk/index path
                    // so a bare `poe-data-extract <path>` just works.
                    if (ggpkPath is null && !args[i].StartsWith("--")) ggpkPath = args[i];
                    break;
            }
        }
        if (ggpkPath is null) { PrintUsage(); return 1; }
        if (!File.Exists(ggpkPath)) { Console.Error.WriteLine($"GGPK not found: {ggpkPath}"); return 2; }

        // Default the output straight into the repo's data/ folder.
        outDir ??= RepoDataDir.Resolve();
        Directory.CreateDirectory(outDir);
        Console.Out.WriteLine($"extract-all → {outDir}");
        using var ggpk = GgpkOpener.Open(ggpkPath);

        // MapMods renders nicer tooltips when the existing stat-description
        // map sits in the same data/ folder — wire it up automatically.
        var mapMods = new MapMods();
        string statDescMap = Path.Combine(outDir, "stat_desc_map.tsv");
        if (File.Exists(statDescMap)) mapMods.StatDescMapPath = statDescMap;

        // (extractor, output-filename, label, optional) — ordered
        // cheapest-first so a failure on a later one still leaves something
        // useful. `optional` tasks log on failure but don't fail the batch.
        var tasks = new (IExtractor extractor, string filename, string label, bool optional)[]
        {
            // BaseItemSizes carries Id + Name + Width + Height in one
            // TSV — base_item_name_map.tsv would be a strict subset, so
            // the helper just reads names from base_item_sizes.tsv too.
            (new StatNames(),     "stat_name_map.tsv",         "stat names",              false),
            (new BaseItemSizes(), "base_item_sizes.tsv",       "base item sizes + names", false),
            (new MonsterNames(),  "monster_name_map.tsv",      "monster names",           false),
            (new Mods(),          "mod_name_map.tsv",          "mod names",               false),
            (new UniqueNames(),   "unique_item_name_map.tsv",  "unique item names",       false),
            (mapMods,             "map_mod_list.tsv",          "map mods",                true),
        };

        int ok = 0, fail = 0;
        foreach (var t in tasks)
        {
            string outPath = Path.Combine(outDir, t.filename);
            try
            {
                t.extractor.Run(ggpk.Index, outPath);
                ok++;
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine($"{(t.optional ? "WARN" : "FAIL")} {t.label}: {ex.Message}");
                if (!t.optional) fail++;
            }
        }
        Console.Out.WriteLine($"extract-all: {ok} ok, {fail} failed");
        return fail == 0 ? 0 : 4;
    }

    private static int RunInspect(ReadOnlySpan<string> args)
    {
        var opts = ParseArgs(args);
        if (opts is null) { PrintUsage(); return 1; }
        if (!File.Exists(opts.GgpkPath)) { Console.Error.WriteLine($"GGPK not found: {opts.GgpkPath}"); return 2; }

        using var ggpk = GgpkOpener.Open(opts.GgpkPath);
        var writer = opts.OutputPath is null
            ? Console.Out
            : new StreamWriter(opts.OutputPath);
        try
        {
            DatInspector.Inspect(ggpk.Index, opts.Table, writer);
        }
        finally
        {
            if (opts.OutputPath is not null) writer.Dispose();
        }
        if (opts.OutputPath is not null) Console.Out.WriteLine($"OK — wrote {opts.OutputPath}");
        return 0;
    }

    /// <summary>
    /// Lists every file in the index whose path contains the given
    /// substring (case-insensitive). Used to locate moved / renamed
    /// files when an expected internal path 404s.
    ///
    /// Usage: poe-data-extract ls --ggpk &lt;c.ggpk|_.index.bin&gt; --match &lt;substr&gt; [--output list.txt]
    /// </summary>
    private static int RunLs(ReadOnlySpan<string> args)
    {
        string? ggpkPath = null, match = null, outputPath = null;
        for (int i = 0; i < args.Length; i++)
        {
            switch (args[i])
            {
                case "--ggpk":   if (++i < args.Length) ggpkPath   = args[i]; break;
                case "--match":  if (++i < args.Length) match      = args[i]; break;
                case "--output": if (++i < args.Length) outputPath = args[i]; break;
            }
        }
        if (ggpkPath is null || match is null)
        {
            Console.Error.WriteLine("usage: poe-data-extract ls --ggpk <path> --match <substring> [--output list.txt]");
            return 1;
        }
        if (!File.Exists(ggpkPath)) { Console.Error.WriteLine($"GGPK not found: {ggpkPath}"); return 2; }

        using var ggpk = GgpkOpener.Open(ggpkPath);
        var writer = outputPath is null ? Console.Out : new StreamWriter(outputPath);
        try
        {
            int n = 0;
            foreach (var kv in ggpk.Index.Files)
            {
                var p = kv.Value.Path;
                if (p is null) continue;
                if (p.Contains(match, StringComparison.OrdinalIgnoreCase))
                {
                    writer.WriteLine(p);
                    n++;
                }
            }
            writer.Flush();
            Console.Out.WriteLine($"{n} matches");
        }
        finally
        {
            if (outputPath is not null) writer.Dispose();
        }
        return 0;
    }

    /// <summary>
    /// Dumps the raw bytes of a single file inside the GGPK/bundles to
    /// stdout or to <c>--output</c>. Used for reverse-engineering shaders
    /// or any other text/binary blob we need to inspect locally.
    ///
    /// Usage: poe-data-extract cat --ggpk &lt;path&gt; --path &lt;internal/path&gt; [--output &lt;file&gt;]
    /// </summary>
    private static int RunCat(ReadOnlySpan<string> args)
    {
        string? ggpkPath = null, internalPath = null, outputPath = null;
        for (int i = 0; i < args.Length; i++)
        {
            switch (args[i])
            {
                case "--ggpk":   if (++i < args.Length) ggpkPath     = args[i]; break;
                case "--path":   if (++i < args.Length) internalPath = args[i]; break;
                case "--output": if (++i < args.Length) outputPath   = args[i]; break;
            }
        }
        if (ggpkPath is null || internalPath is null)
        {
            Console.Error.WriteLine("usage: poe-data-extract cat --ggpk <path> --path <internal/path> [--output <file>]");
            return 1;
        }
        if (!File.Exists(ggpkPath)) { Console.Error.WriteLine($"GGPK not found: {ggpkPath}"); return 2; }

        using var ggpk = GgpkOpener.Open(ggpkPath);
        if (!ggpk.Index.TryFindNode(internalPath, out var node)
            || node is not LibBundle3.Nodes.FileNode file)
        {
            Console.Error.WriteLine($"Not found in GGPK: {internalPath}");
            return 3;
        }
        var bytes = file.Record.Read();
        if (outputPath is null)
            using (var stdout = Console.OpenStandardOutput())
                stdout.Write(bytes.Span);
        else
            File.WriteAllBytes(outputPath, bytes.ToArray());
        return 0;
    }

    private sealed record Options(
        string GgpkPath,
        string Table,
        string? OutputPath,
        int? ModDomain,
        string? StatDescMap);

    private static Options? ParseArgs(ReadOnlySpan<string> args)
    {
        string? ggpk = null, table = null, output = null, statDescMap = null;
        int? modDomain = null;
        for (int i = 0; i < args.Length; i++)
        {
            switch (args[i])
            {
                case "--ggpk":          if (++i < args.Length) ggpk        = args[i]; break;
                case "--table":         if (++i < args.Length) table       = args[i]; break;
                case "--output":        if (++i < args.Length) output      = args[i]; break;
                // --mod-domain only meaningful for the MapMods extractor;
                // ignored elsewhere. Allows the same extractor binary to
                // pull a different ModDomain bucket without a rebuild.
                case "--mod-domain":    if (++i < args.Length && int.TryParse(args[i], out var d)) modDomain = d; break;
                // --stat-desc-map enables MapMods' tooltip-rendering pass.
                // Points at the existing data/stat_desc_map.tsv (Python-
                // generated). Ignored by other extractors.
                case "--stat-desc-map": if (++i < args.Length) statDescMap = args[i]; break;
            }
        }
        if (ggpk is null || table is null) return null;
        return new Options(ggpk, table, output, modDomain, statDescMap);
    }

    private static int Fail(string msg, int code) { Console.Error.WriteLine(msg); return code; }

    // The verbs the dispatcher recognises. Anything else that looks like a
    // path is treated as the bare-path extract-all convenience form.
    private static bool IsKnownVerb(string verb) => verb is
        "extract" or "extract-all" or "inspect" or "ls" or "cat";

    // True when the token looks like a ggpk/index path rather than a verb —
    // it exists on disk, or carries the expected extension.
    private static bool LooksLikePath(string s) =>
        File.Exists(s)
        || s.EndsWith(".ggpk", StringComparison.OrdinalIgnoreCase)
        || s.EndsWith(".bin", StringComparison.OrdinalIgnoreCase);

    private static bool HasFlag(string[] args, string flag)
    {
        foreach (var a in args)
            if (a.Equals(flag, StringComparison.OrdinalIgnoreCase)) return true;
        return false;
    }

    // Best-effort ggpk/index path for anchoring the Oodle scan on the right
    // drive: the --ggpk value if present, else the first path-shaped token.
    private static string? FindGgpkHint(string[] args)
    {
        for (int i = 0; i + 1 < args.Length; i++)
            if (args[i].Equals("--ggpk", StringComparison.OrdinalIgnoreCase)) return args[i + 1];
        foreach (var a in args)
            if (!a.StartsWith("--") && LooksLikePath(a)) return a;
        return null;
    }

    private static void PrintUsage()
    {
        Console.Error.WriteLine("usage: poe-data-extract <path>          (bare path → extract-all into the repo data/ folder)");
        Console.Error.WriteLine("       poe-data-extract extract-all [--ggpk] <path> [--output-dir <dir>]");
        Console.Error.WriteLine("       poe-data-extract extract --ggpk <path> --table <Name> --output <out.tsv>");
        Console.Error.WriteLine("                                [--mod-domain <N>] [--stat-desc-map <path>]");
        Console.Error.WriteLine("       poe-data-extract inspect --ggpk <path> --table <Name> [--output <dump.txt>]");
        Console.Error.WriteLine("       poe-data-extract ls      --ggpk <path> --match <substr> [--output <list.txt>]");
        Console.Error.WriteLine("       poe-data-extract cat     --ggpk <path> --path <internal/path> [--output <file>]");
        Console.Error.WriteLine("       extract-all writes: base_item_sizes, monster_name_map, stat_name_map,");
        Console.Error.WriteLine("                           mod_name_map, unique_item_name_map, map_mod_list (.tsv)");
        Console.Error.WriteLine("       known tables (extract): BaseItemTypes, MonsterNames, StatNames, Mods, MapMods, UniqueNames");
        Console.Error.WriteLine("       --mod-domain      only applies to MapMods (default 5 = AREA / map mods)");
        Console.Error.WriteLine("       --stat-desc-map   only applies to MapMods; path to data/stat_desc_map.tsv");
        Console.Error.WriteLine("                         enables in-game-style tooltip rendering per mod row");
        Console.Error.WriteLine("       --no-prompt       never show the interactive oo2core.dll file picker");
        Console.Error.WriteLine("       <path> = either Content.ggpk or Bundles2/_.index.bin");
        Console.Error.WriteLine("       Missing oo2core.dll is auto-copied from a local Steam game (e.g. PoE 1).");
    }
}
