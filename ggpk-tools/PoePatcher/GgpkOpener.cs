using LibBundle3;
using LibBundle3.Nodes;
using LibBundledGGPK3;
using Index = LibBundle3.Index;

namespace PoePatcher;

/// <summary>
/// Same wrapper as PoeDataExtract's — see that file for rationale.
/// Duplicated rather than shared because the two CLI projects are
/// fully self-contained (no shared library DLL to ship).
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
            if (path.EndsWith(".index.bin", StringComparison.OrdinalIgnoreCase))
            {
                // See PoeDataExtract/GgpkOpener.cs for why this dance.
                var idx = new TolerantIndex(path);
                idx.ParsePaths();
                return new GgpkOpener(idx, idx);
            }
            var ggpk = new BundledGGPK(path, parsePathsInIndex: true);
            return new GgpkOpener(ggpk, ggpk.Index);
        }
        catch (DllNotFoundException ex) when (ex.Message.Contains("oo2core", StringComparison.OrdinalIgnoreCase))
        {
            throw new DllNotFoundException(
                "oo2core (Oodle) DLL not found. PoE2 doesn't ship it externally.\n" +
                "  Copy 'oo2core_9_win64.dll' next to the .exe (or into the working directory).\n" +
                "  Sources: a PoE1 install root, VisualGGPK3 release zips, or any other\n" +
                "  Oodle-using game (Cyberpunk, Apex Legends, Warframe, Manor Lords, ...).",
                ex);
        }
    }

    public void Save() => Index.Save();

    public void Dispose() => _backing.Dispose();

    private sealed class TolerantIndex : Index
    {
        private DirectoryNode? _root;
        public TolerantIndex(string filePath) : base(filePath, parsePaths: false) { }
        public override DirectoryNode Root => _root ??= BuildTree(ignoreNullPath: true);
    }
}
