using GgpkTools;
using LibBundle3;
using PoePatcher.Patches;

namespace PoePatcher;

/// <summary>
/// CLI entry for one-shot GGPK modifications.
///
/// Usage:
///     poe-patcher apply  --ggpk &lt;Content.ggpk&gt; --patch &lt;name&gt;
///     poe-patcher revert --ggpk &lt;Content.ggpk&gt; --patch &lt;name&gt;
///     poe-patcher list                              # available patches
///
/// Exit codes:
///     0  success
///     1  bad args / unknown patch
///     2  GGPK could not be opened
///     3  patch could not be applied (target file missing, marker not found)
///     4  no backup available to revert
/// </summary>
internal static class Program
{
    private static readonly IReadOnlyDictionary<string, IPatch> Patches =
        new Dictionary<string, IPatch>(StringComparer.OrdinalIgnoreCase)
        {
            ["minimap"] = new MinimapPatch(),
        };

    [STAThread] // required for the comdlg32 file picker the Oodle resolver may show
    private static int Main(string[] args)
    {
        if (args.Length == 0) { PrintUsage(); return 1; }

        string verb = args[0];
        if (verb.Equals("list", StringComparison.OrdinalIgnoreCase))
        {
            foreach (var kv in Patches)
                Console.Out.WriteLine($"{kv.Key}\t{kv.Value.Description}");
            return 0;
        }

        // Every remaining verb opens a bundle, so make the Oodle native DLL
        // available first. Prompt only for genuine manual CLI use (stdio not
        // redirected, no --no-prompt) so the AHK shell-out never pops a dialog.
        bool allowPrompt = !HasFlag(args, "--no-prompt")
            && !Console.IsErrorRedirected && !Console.IsInputRedirected;
        OodleResolver.EnsureAvailable(FindGgpkHint(args), allowPrompt);

        if (verb.Equals("extract", StringComparison.OrdinalIgnoreCase))
            return RunExtract(args.AsSpan(1));

        Options? opts;
        try
        {
            opts = ParseArgs(args.AsSpan(1));
        }
        catch (ArgumentException ex)
        {
            // Hex-parsing failures land here — print and bail with
            // exit-1 (bad-args) rather than blowing up with a stack
            // trace, since the AHK bridge tries to parse stderr too.
            Console.Error.WriteLine(ex.Message);
            return 1;
        }
        if (opts is null) { PrintUsage(); return 1; }

        if (!Patches.TryGetValue(opts.PatchName, out var patch))
        {
            Console.Error.WriteLine($"Unknown patch: {opts.PatchName}");
            return 1;
        }

        if (!File.Exists(opts.GgpkPath))
        {
            Console.Error.WriteLine($"GGPK not found: {opts.GgpkPath}");
            return 2;
        }

        try
        {
            // Opened read/write so the patch can mutate file contents
            // in place. LibBundle3 handles bundle recompression for us.
            using var ggpk = GgpkOpener.Open(opts.GgpkPath);
            var backups = new BackupManager(opts.GgpkPath);

            // Patch-specific options: when the user passes
            // `--minimap-outline` / `--minimap-background` and the
            // selected patch is the MinimapPatch, push the parsed
            // colors into the patch instance before Apply.
            if (patch is MinimapPatch mp)
            {
                if (opts.MinimapOutline    is var o && o.HasValue) mp.OutlineColor    = o.Value;
                if (opts.MinimapBackground is var b && b.HasValue) mp.BackgroundColor = b.Value;
            }

            return verb.ToLowerInvariant() switch
            {
                "apply"  => RunApply (ggpk, backups, patch, opts.DryRun, opts.GgpkPath),
                "revert" => RunRevert(ggpk, backups, patch, opts.DryRun, opts.GgpkPath),
                _ => Fail("Unknown verb (expected apply|revert|list|extract)", 1),
            };
        }
        catch (FileNotFoundException ex)
        {
            Console.Error.WriteLine($"Target file missing inside GGPK: {ex.Message}");
            return 3;
        }
        catch (InvalidOperationException ex)
        {
            Console.Error.WriteLine($"Patch failed: {ex.Message}");
            return 3;
        }
    }

    private static int RunApply(GgpkOpener ggpk, BackupManager backups, IPatch patch, bool dryRun, string ggpkPath)
    {
        patch.Apply(ggpk.Index, backups);
        if (dryRun)
        {
            Console.Out.WriteLine($"DRY-RUN — '{patch.Name}' applied in memory, NO disk writes.");
            Console.Out.WriteLine($"          (shader marker matches confirmed, safe to re-run without --dry-run)");
            return 0;
        }
        SnapshotIndexFile(ggpkPath, backups, patch.Name);
        ggpk.Save();
        Console.Out.WriteLine($"OK — applied '{patch.Name}' (backups under <ggpkdir>/backups/{patch.Name}/)");
        return 0;
    }

    private static int RunRevert(GgpkOpener ggpk, BackupManager backups, IPatch patch, bool dryRun, string ggpkPath)
    {
        if (!backups.HasBackupsFor(patch.Name))
        {
            Console.Error.WriteLine($"No backups recorded for '{patch.Name}'.");
            return 4;
        }
        patch.Revert(ggpk.Index, backups);
        if (dryRun)
        {
            Console.Out.WriteLine($"DRY-RUN — '{patch.Name}' reverted in memory, NO disk writes.");
            return 0;
        }
        ggpk.Save();
        Console.Out.WriteLine($"OK — reverted '{patch.Name}'");
        return 0;
    }

    /// <summary>
    /// Defense-in-depth: before any <c>Index.Save()</c> that mutates the
    /// bundle index, copy the current <c>_.index.bin</c> verbatim into
    /// the backup directory. If our own per-file backup machinery
    /// somehow fails to round-trip cleanly, the user can manually
    /// restore the snapshot to undo any structural index corruption.
    /// </summary>
    private static void SnapshotIndexFile(string ggpkPath, BackupManager backups, string patchName)
    {
        // Only applies to the bare-index form; for legacy Content.ggpk
        // there's nothing useful to snapshot at this layer.
        if (!ggpkPath.EndsWith(".index.bin", StringComparison.OrdinalIgnoreCase)) return;
        var dst = Path.Combine(backups.RootDirectory, patchName, "_index_snapshot.bin");
        Directory.CreateDirectory(Path.GetDirectoryName(dst)!);
        if (!File.Exists(dst))  // first-apply only; don't clobber the pristine snapshot
            File.Copy(ggpkPath, dst);
    }

    /// <summary>
    /// Read-only helper. Pulls a single internal file out of the GGPK
    /// to a local path so we can inspect its contents (e.g. to find the
    /// exact shader substrings MinimapPatch should target).
    ///
    /// Usage: poe-patcher extract --ggpk &lt;c.ggpk&gt; --path shaders/foo.hlsl --output foo.hlsl
    /// </summary>
    private static int RunExtract(ReadOnlySpan<string> args)
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
        if (ggpkPath is null || internalPath is null || outputPath is null)
        {
            Console.Error.WriteLine("usage: poe-patcher extract --ggpk <Content.ggpk> --path <internal/path> --output <out>");
            return 1;
        }
        if (!File.Exists(ggpkPath)) { Console.Error.WriteLine($"GGPK not found: {ggpkPath}"); return 2; }

        using var ggpk = GgpkOpener.Open(ggpkPath);
        if (!ggpk.Index.TryFindNode(internalPath, out var node) || node is not LibBundle3.Nodes.FileNode file)
        {
            Console.Error.WriteLine($"Internal file not found: {internalPath}");
            return 3;
        }
        var bytes = file.Record.Read().ToArray();
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(outputPath))!);
        File.WriteAllBytes(outputPath, bytes);
        Console.Out.WriteLine($"OK — extracted {internalPath} ({bytes.Length} bytes) → {outputPath}");
        return 0;
    }

    private sealed record Options(
        string GgpkPath, string PatchName, bool DryRun,
        (float R, float G, float B, float A)? MinimapOutline,
        (float R, float G, float B, float A)? MinimapBackground);

    private static Options? ParseArgs(ReadOnlySpan<string> args)
    {
        string? ggpk = null, patch = null;
        bool dryRun = false;
        (float, float, float, float)? outline = null;
        (float, float, float, float)? background = null;
        for (int i = 0; i < args.Length; i++)
        {
            switch (args[i])
            {
                case "--ggpk":    if (++i < args.Length) ggpk  = args[i]; break;
                case "--patch":   if (++i < args.Length) patch = args[i]; break;
                case "--dry-run": dryRun = true; break;
                case "--minimap-outline":
                    if (++i < args.Length) outline = ParseRgba(args[i], "--minimap-outline");
                    break;
                case "--minimap-background":
                    if (++i < args.Length) background = ParseRgba(args[i], "--minimap-background");
                    break;
            }
        }
        if (ggpk is null || patch is null) return null;
        return new Options(ggpk, patch, dryRun, outline, background);
    }

    /// <summary>
    /// Parses a 6- or 8-character hex string (with optional <c>#</c>
    /// prefix) into a normalized (R, G, B, A) tuple in 0..1. Missing
    /// alpha (6-char input) defaults to fully opaque. Invalid input is
    /// a fatal ArgumentException — colors silently falling back to
    /// random values would be worse than a clear "bad CLI arg" failure.
    /// </summary>
    private static (float R, float G, float B, float A) ParseRgba(string hex, string argName)
    {
        string h = hex.StartsWith('#') ? hex[1..] : hex;
        if (h.Length != 6 && h.Length != 8)
            throw new ArgumentException(
                $"{argName} expects 6 or 8 hex chars (RRGGBB or RRGGBBAA); got \"{hex}\"");
        try
        {
            byte r = Convert.ToByte(h[0..2], 16);
            byte g = Convert.ToByte(h[2..4], 16);
            byte b = Convert.ToByte(h[4..6], 16);
            byte a = h.Length == 8 ? Convert.ToByte(h[6..8], 16) : (byte)255;
            return (r / 255f, g / 255f, b / 255f, a / 255f);
        }
        catch (FormatException ex)
        {
            throw new ArgumentException($"{argName}: malformed hex \"{hex}\": {ex.Message}", ex);
        }
    }

    private static int Fail(string msg, int code)
    {
        Console.Error.WriteLine(msg);
        return code;
    }

    private static bool HasFlag(string[] args, string flag)
    {
        foreach (var a in args)
            if (a.Equals(flag, StringComparison.OrdinalIgnoreCase)) return true;
        return false;
    }

    // The --ggpk value, used to anchor the Oodle scan on the right drive.
    private static string? FindGgpkHint(string[] args)
    {
        for (int i = 0; i + 1 < args.Length; i++)
            if (args[i].Equals("--ggpk", StringComparison.OrdinalIgnoreCase)) return args[i + 1];
        return null;
    }

    private static void PrintUsage()
    {
        Console.Error.WriteLine("usage: poe-patcher <apply|revert> --ggpk <path> --patch <name> [--dry-run]");
        Console.Error.WriteLine("                                  [--minimap-outline RRGGBBAA]");
        Console.Error.WriteLine("                                  [--minimap-background RRGGBBAA]");
        Console.Error.WriteLine("       poe-patcher extract --ggpk <path> --path <internal/path> --output <out>");
        Console.Error.WriteLine("       poe-patcher list");
        Console.Error.WriteLine();
        Console.Error.WriteLine("  <path>     = Content.ggpk or Bundles2/_.index.bin");
        Console.Error.WriteLine("  --dry-run  = apply the patch in memory only — verifies marker matches,");
        Console.Error.WriteLine("               does NOT call Index.Save() so no disk writes happen.");
        Console.Error.WriteLine("  --minimap-outline / --minimap-background  = hex RGB(A) overrides for");
        Console.Error.WriteLine("               MinimapPatch's two color literals. 6 or 8 chars,");
        Console.Error.WriteLine("               with optional leading '#'. Missing alpha = FF (opaque).");
    }
}
