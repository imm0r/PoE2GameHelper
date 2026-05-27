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
    private static int Main(string[] args)
    {
        if (args.Length == 0) { PrintUsage(); return 1; }

        string verb = args[0].ToLowerInvariant();
        var rest = args.AsSpan(1);

        try
        {
            return verb switch
            {
                "extract"     => RunExtract(rest),
                "extract-all" => RunExtractAll(rest),
                "inspect"     => RunInspect(rest),
                "ls"          => RunLs(rest),
                "cat"         => RunCat(rest),
                _ => Fail($"Unknown verb: {verb}", 1),
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
        if (extractor is MapMods mapMods && opts.ModDomain is int d)
            mapMods.DomainFilter = d;
        extractor.Run(ggpk.Index, opts.OutputPath);
        Console.Out.WriteLine($"OK — wrote {opts.OutputPath}");
        return 0;
    }

    /// <summary>
    /// Refreshes every TSV the helper consumes in one shell-out. Opens
    /// the GGPK once and runs each extractor against it — saves the
    /// ~300 ms .NET-startup cost of invoking the tool 5x.
    ///
    /// Usage: poe-data-extract extract-all --ggpk &lt;path&gt; --output-dir &lt;dir&gt;
    ///
    /// Each extractor writes a fixed filename inside output-dir:
    ///     base_item_sizes.tsv          (BaseItemSizes)
    ///     base_item_name_map.tsv       (BaseItemNames)
    ///     monster_name_map.tsv         (MonsterNames)
    ///     stat_name_map.tsv            (StatNames)
    ///     mod_name_map.tsv             (Mods)
    /// UniqueNames is NOT in the all-set (placeholder — throws if invoked).
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
            }
        }
        if (ggpkPath is null || outDir is null) { PrintUsage(); return 1; }
        if (!File.Exists(ggpkPath)) { Console.Error.WriteLine($"GGPK not found: {ggpkPath}"); return 2; }

        Directory.CreateDirectory(outDir);
        using var ggpk = GgpkOpener.Open(ggpkPath);

        // (extractor, output-filename) pairs — ordered cheapest-first
        // so a failure on a later one still leaves something useful.
        var tasks = new (IExtractor extractor, string filename, string label)[]
        {
            // BaseItemSizes carries Id + Name + Width + Height in one
            // TSV — base_item_name_map.tsv would be a strict subset, so
            // the helper just reads names from base_item_sizes.tsv too.
            (new StatNames(),     "stat_name_map.tsv",    "stat names"),
            (new BaseItemSizes(), "base_item_sizes.tsv",  "base item sizes + names"),
            (new MonsterNames(),  "monster_name_map.tsv", "monster names"),
            (new Mods(),          "mod_name_map.tsv",          "mod names"),
            (new UniqueNames(),   "unique_item_name_map.tsv",  "unique item names"),
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
                Console.Error.WriteLine($"FAIL {t.label}: {ex.Message}");
                fail++;
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

    private sealed record Options(string GgpkPath, string Table, string? OutputPath, int? ModDomain);

    private static Options? ParseArgs(ReadOnlySpan<string> args)
    {
        string? ggpk = null, table = null, output = null;
        int? modDomain = null;
        for (int i = 0; i < args.Length; i++)
        {
            switch (args[i])
            {
                case "--ggpk":       if (++i < args.Length) ggpk   = args[i]; break;
                case "--table":      if (++i < args.Length) table  = args[i]; break;
                case "--output":     if (++i < args.Length) output = args[i]; break;
                // --mod-domain only meaningful for the MapMods extractor;
                // ignored elsewhere. Allows the same extractor binary to
                // pull a different ModDomain bucket without a rebuild.
                case "--mod-domain": if (++i < args.Length && int.TryParse(args[i], out var d)) modDomain = d; break;
            }
        }
        if (ggpk is null || table is null) return null;
        return new Options(ggpk, table, output, modDomain);
    }

    private static int Fail(string msg, int code) { Console.Error.WriteLine(msg); return code; }

    private static void PrintUsage()
    {
        Console.Error.WriteLine("usage: poe-data-extract extract --ggpk <path> --table <Name> --output <out.tsv> [--mod-domain <N>]");
        Console.Error.WriteLine("       poe-data-extract inspect --ggpk <path> --table <Name> [--output <dump.txt>]");
        Console.Error.WriteLine("       poe-data-extract ls      --ggpk <path> --match <substr> [--output <list.txt>]");
        Console.Error.WriteLine("       poe-data-extract cat     --ggpk <path> --path <internal/path> [--output <file>]");
        Console.Error.WriteLine("       known tables (extract): BaseItemTypes, MonsterNames, StatNames, Mods, MapMods, UniqueNames");
        Console.Error.WriteLine("       --mod-domain only applies to MapMods (default 5 = AREA / map mods)");
        Console.Error.WriteLine("       <path> = either Content.ggpk or Bundles2/_.index.bin");
    }
}
