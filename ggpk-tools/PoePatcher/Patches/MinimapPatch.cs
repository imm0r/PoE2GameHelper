using System.Text;
using LibBundle3;
using Index = LibBundle3.Index;
using LibBundle3.Nodes;

namespace PoePatcher.Patches;

/// <summary>
/// Reveals the entire minimap by patching the two shader files that
/// gate visibility on the per-cell explored flag.
///
/// PoE2 0.x shader analysis (May 2026):
///
/// <c>shaders/minimap_visibility_pixel.hlsl</c> writes the explored mask
/// (red channel of <c>curr_visibility_sampler</c>). The line
/// <c>res_color = max(res_color, 0.180);</c> clamps to a 0.18 minimum
/// floor on already-explored cells. Bumping that floor to <c>1.000</c>
/// makes every cell render as fully explored regardless of the actual
/// reveal ratio.
///
/// <c>shaders/minimap_blending_pixel.hlsl</c> reads <c>visibility</c>
/// from <c>walkability_sample.g</c> and uses it to multiply the
/// rendered geometry/walkability alpha. Hardcoding <c>visibility = 1</c>
/// makes the blending pass draw the geometry at full strength even on
/// never-explored cells.
///
/// Together these two changes reveal the whole minimap without
/// touching network code or shader-compile-time conditional branches.
/// Find strings are deliberately specific so a future patch that
/// rewrites either shader fails loud (<c>"Marker not found"</c>) rather
/// than silently corrupting the file.
/// </summary>
internal sealed class MinimapPatch : IPatch
{
    public string Name => "minimap";
    public string Description => "Reveal full minimap (modifies shaders/minimap_*.hlsl).";

    private static readonly (string Path, string Find, string Replace)[] Edits =
    {
        (
            "shaders/minimap_visibility_pixel.hlsl",
            "res_color = max(res_color, 0.180);",
            "res_color = max(res_color, 1.000); // PoE2GameHelper: forced-reveal"
        ),
        (
            "shaders/minimap_blending_pixel.hlsl",
            "float visibility = saturate(walkability_sample.g * 2.0f);",
            "float visibility = 1.0f; // PoE2GameHelper: forced-reveal (was: saturate(walkability_sample.g * 2.0f))"
        ),
    };

    public void Apply(Index index, BackupManager backups)
    {
        foreach (var edit in Edits)
        {
            var file = ResolveFile(index, edit.Path);
            var original = file.Record.Read();
            backups.Save(Name, edit.Path, original.Span);

            // Shaders are ASCII / UTF-8 text. Decoding the whole file is
            // cheap (a few KB per shader) and lets us do a plain string
            // replace, which is far less error-prone than hex search.
            string text = Encoding.UTF8.GetString(original.Span);
            if (!text.Contains(edit.Find, StringComparison.Ordinal))
                throw new InvalidOperationException(
                    $"Marker not found in {edit.Path}: \"{edit.Find}\" — has the shader changed in a patch?");

            string patched = text.Replace(edit.Find, edit.Replace);
            file.Record.Write(Encoding.UTF8.GetBytes(patched));
        }
    }

    public void Revert(Index index, BackupManager backups)
    {
        foreach (var edit in Edits)
        {
            var file = ResolveFile(index, edit.Path);
            var original = backups.Load(Name, edit.Path);
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
