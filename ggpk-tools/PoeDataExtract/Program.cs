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
                "extract" => RunExtract(rest),
                "inspect" => RunInspect(rest),
                "ls"      => RunLs(rest),
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
        IExtractor extractor = opts.Table switch
        {
            "BaseItemTypes" => new BaseItemSizes(),
            _ => throw new ArgumentException($"Unknown table: {opts.Table}"),
        };
        extractor.Run(ggpk.Index, opts.OutputPath);
        Console.Out.WriteLine($"OK — wrote {opts.OutputPath}");
        return 0;
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

    private sealed record Options(string GgpkPath, string Table, string? OutputPath);

    private static Options? ParseArgs(ReadOnlySpan<string> args)
    {
        string? ggpk = null, table = null, output = null;
        for (int i = 0; i < args.Length; i++)
        {
            switch (args[i])
            {
                case "--ggpk":   if (++i < args.Length) ggpk   = args[i]; break;
                case "--table":  if (++i < args.Length) table  = args[i]; break;
                case "--output": if (++i < args.Length) output = args[i]; break;
            }
        }
        if (ggpk is null || table is null) return null;
        return new Options(ggpk, table, output);
    }

    private static int Fail(string msg, int code) { Console.Error.WriteLine(msg); return code; }

    private static void PrintUsage()
    {
        Console.Error.WriteLine("usage: poe-data-extract extract --ggpk <path> --table <Name> --output <out.tsv>");
        Console.Error.WriteLine("       poe-data-extract inspect --ggpk <path> --table <Name> [--output <dump.txt>]");
        Console.Error.WriteLine("       poe-data-extract ls      --ggpk <path> --match <substr> [--output <list.txt>]");
        Console.Error.WriteLine("       known tables (extract): BaseItemTypes");
        Console.Error.WriteLine("       <path> = either Content.ggpk or Bundles2/_.index.bin");
    }
}
