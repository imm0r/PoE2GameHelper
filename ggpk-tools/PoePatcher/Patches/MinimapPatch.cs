using System.Text;
using LibBundle3;
using Index = LibBundle3.Index;
using LibBundle3.Nodes;

namespace PoePatcher.Patches;

/// <summary>
/// Reveals the entire minimap by patching the two shader files that
/// gate visibility on the per-cell explored flag, AND optionally
/// recolors the two hardcoded fill/outline color literals that the
/// blending shader uses for revealed-but-unexplored geometry.
///
/// PoE2 0.x shader analysis (verified May 2026):
///
/// <c>shaders/minimap_visibility_pixel.hlsl</c> writes the explored
/// mask (red channel of <c>curr_visibility_sampler</c>). It computes
/// a <c>ratio</c> from distance to the explored tile, then writes
/// <c>(ratio, 0, 0, 1)</c>. Forcing <c>ratio = 1.0</c> at its source
/// makes every cell render as fully explored.
///
/// <c>shaders/minimap_blending_pixel.hlsl</c> reads <c>visibility</c>
/// from <c>walkability_sample.g</c> and uses it to multiply the
/// rendered geometry / walkability alpha. Hardcoding
/// <c>visibility = 1</c> makes the blending pass draw the geometry
/// at full strength even on never-explored cells.
///
/// The blending shader also has two literal <c>float4(...)</c>
/// colors that paint walkable areas: an interior "background" tint
/// (originally <c>(1,1,1,0.01)</c> — a near-invisible white wash
/// that becomes a visible gray veil once we force visibility=1),
/// and an "outline" color at walkable-to-wall transitions (originally
/// <c>(0.5,0.5,1,0.5)</c>). We swap both for caller-provided RGBA
/// values so the user can tune the look.
///
/// History: an earlier version of this patch targeted a
/// <c>res_color = max(res_color, 0.180);</c> line in the visibility
/// shader; GGG removed that line in a patch around May 25 2026.
/// We now target <c>ratio</c> directly, which is structurally more
/// stable (the function HAS to compute a visibility ratio somehow).
/// </summary>
internal sealed class MinimapPatch : IPatch
{
    public string Name => "minimap";
    public string Description => "Reveal full minimap (modifies shaders/minimap_*.hlsl).";

    // RGBA in 0..1 floats. Sane defaults: outline keeps the game's
    // original blue-ish wall ramp at high opacity; background gets a
    // faint Exile-Forge-like green tint so the user can tell at a
    // glance "this is revealed-but-unexplored." Both are caller-
    // overridable via the CLI flags `--minimap-outline RRGGBBAA` and
    // `--minimap-background RRGGBBAA` in PoePatcher.Program.
    public (float R, float G, float B, float A) OutlineColor    { get; set; } = (0.5f, 0.5f, 1.0f, 0.8f);
    public (float R, float G, float B, float A) BackgroundColor { get; set; } = (0.4f, 1.0f, 0.4f, 0.10f);

    private const string OutlineMarker    = "float4(0.5f, 0.5f, 1.0f, 0.5f)";
    private const string BackgroundMarker = "float4(1.0f, 1.0f, 1.0f, 0.01f)";

    public void Apply(Index index, BackupManager backups)
    {
        // 1) Visibility shader — force the explored mask to 1 everywhere.
        ApplySimpleReplace(
            index, backups,
            "shaders/minimap_visibility_pixel.hlsl",
            "float ratio = saturate((1.0f - dist / visibility_radius) * 2.0f);",
            "float ratio = 1.0f; // PoE2GameHelper: forced-reveal");

        // 2) Blending shader — three coupled edits in one file. We do
        //    these in a single read/write so we never half-patch the
        //    shader and leave it in a bad intermediate state.
        const string blendPath = "shaders/minimap_blending_pixel.hlsl";
        var blendFile = ResolveFile(index, blendPath);
        var original = blendFile.Record.Read();
        backups.Save(Name, blendPath, original.Span);
        string text = Encoding.UTF8.GetString(original.Span);

        text = ReplaceOnce(text, blendPath,
            "float visibility = saturate(walkability_sample.g * 2.0f);",
            "float visibility = 1.0f; // PoE2GameHelper: forced-reveal");
        text = ReplaceOnce(text, blendPath,
            OutlineMarker,
            FormatColor(OutlineColor) + " /* PoE2GameHelper: outline */");
        text = ReplaceOnce(text, blendPath,
            BackgroundMarker,
            FormatColor(BackgroundColor) + " /* PoE2GameHelper: background */");

        blendFile.Record.Write(Encoding.UTF8.GetBytes(text));
    }

    private void ApplySimpleReplace(Index index, BackupManager backups,
        string path, string find, string replace)
    {
        var file = ResolveFile(index, path);
        var original = file.Record.Read();
        backups.Save(Name, path, original.Span);
        string text = Encoding.UTF8.GetString(original.Span);
        text = ReplaceOnce(text, path, find, replace);
        file.Record.Write(Encoding.UTF8.GetBytes(text));
    }

    /// <summary>
    /// Plain string replace with a hard "marker must exist" assertion.
    /// We'd rather fail loud with a clear error than silently write an
    /// unmodified file — a missing marker means the shader changed in
    /// an upstream patch and the offsets need re-checking.
    /// </summary>
    private static string ReplaceOnce(string text, string path, string find, string replace)
    {
        if (!text.Contains(find, StringComparison.Ordinal))
            throw new InvalidOperationException(
                $"Marker not found in {path}: \"{find}\" — has the shader changed in a patch?");
        return text.Replace(find, replace);
    }

    /// <summary>
    /// Formats an (R,G,B,A) tuple as HLSL <c>float4(R, G, B, A)</c>
    /// with the same trailing-`f` convention the original literals use,
    /// so the patched shader compiles cleanly under fxc.
    /// </summary>
    private static string FormatColor((float R, float G, float B, float A) c)
        => System.FormattableString.Invariant(
            $"float4({c.R:0.0####}f, {c.G:0.0####}f, {c.B:0.0####}f, {c.A:0.0####}f)");

    // Two shader files participate in the patch. Revert restores both
    // from their pre-Apply backup bytes verbatim; we don't try to undo
    // the edits string-by-string because the backup is exact and any
    // partial-Revert state would be a worse failure mode than the
    // backup-missing case (which surfaces as a clear "no backup found"
    // error from BackupManager.Load).
    private static readonly string[] PatchedShaderPaths =
    {
        "shaders/minimap_visibility_pixel.hlsl",
        "shaders/minimap_blending_pixel.hlsl",
    };

    public void Revert(Index index, BackupManager backups)
    {
        foreach (var path in PatchedShaderPaths)
        {
            var file = ResolveFile(index, path);
            var original = backups.Load(Name, path);
            file.Record.Write(original);
        }
        backups.Clear(Name);
    }

    private static FileNode ResolveFile(Index index, string path)
    {
        if (!index.TryFindNode(path, out var node) || node is not FileNode file)
            throw new FileNotFoundException(path);
        return file;
    }
}
