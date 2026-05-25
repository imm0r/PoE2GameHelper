using LibBundle3;
using LibBundle3.Nodes;
using LibBundledGGPK3;
using Index = LibBundle3.Index;

namespace PoeDataExtract;

/// <summary>
/// Opens either a legacy <c>Content.ggpk</c> shell (PoE1 + early PoE2)
/// OR a bare <c>Bundles2/_.index.bin</c> (PoE2 Steam ships without a
/// GGPK — everything lives in the bundle index directly).
///
/// Returns a disposable wrapper exposing a unified <see cref="Index"/>.
/// The <see cref="FileNode.Record"/> API is identical in both cases, so
/// downstream code never has to branch.
/// </summary>
internal sealed class GgpkOpener : IDisposable
{
    private readonly IDisposable _backing;
    public Index Index { get; }

    private GgpkOpener(IDisposable backing, Index index)
    {
        _backing = backing;
        Index = index;
    }

    public static GgpkOpener Open(string path)
    {
        try
        {
            // PoE2 Steam: no GGPK shell, point straight at _.index.bin.
            // Heuristic by extension keeps the CLI flag simple — the
            // user passes whichever file they have and we DTRT.
            if (path.EndsWith(".index.bin", StringComparison.OrdinalIgnoreCase))
            {
                // parsePaths=true throws on the first un-parseable path —
                // PoE2 0.x has a handful (~5) of those in Data/Misc. Open
                // with parsePaths=false, call ParsePaths() manually so
                // failures are tolerated, and wrap so Root → BuildTree
                // uses ignoreNullPath=true.
                var idx = new TolerantIndex(path);
                idx.ParsePaths();
                return new GgpkOpener(idx, idx);
            }
            var ggpk = new BundledGGPK(path, parsePathsInIndex: true);
            return new GgpkOpener(ggpk, ggpk.Index);
        }
        catch (DllNotFoundException ex) when (ex.Message.Contains("oo2core", StringComparison.OrdinalIgnoreCase))
        {
            // PoE2 statically links Oodle, so the DLL isn't shipped in
            // the install folder. Tell the user where to find one.
            throw new DllNotFoundException(
                "oo2core (Oodle) DLL not found. PoE2 doesn't ship it externally.\n" +
                "  Copy 'oo2core_9_win64.dll' next to the .exe (or into the working directory).\n" +
                "  Sources: a PoE1 install root, VisualGGPK3 release zips, or any other\n" +
                "  Oodle-using game (Cyberpunk, Apex Legends, Warframe, Manor Lords, ...).",
                ex);
        }
    }

    public void Dispose() => _backing.Dispose();

    /// <summary>
    /// Variant of <see cref="Index"/> that tolerates un-parseable paths
    /// by overriding <see cref="Index.Root"/> to use
    /// <c>BuildTree(ignoreNullPath: true)</c>. PoE2 0.x ships a handful
    /// of files whose path encoding LibBundle3 can't decode — without
    /// this override they'd block opening the whole index.
    /// </summary>
    private sealed class TolerantIndex : Index
    {
        private DirectoryNode? _root;
        public TolerantIndex(string filePath) : base(filePath, parsePaths: false) { }
        public override DirectoryNode Root => _root ??= BuildTree(ignoreNullPath: true);
    }
}
