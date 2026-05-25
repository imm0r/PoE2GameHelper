namespace PoePatcher;

/// <summary>
/// Stores the original bytes of every file a patch overwrites so the
/// modification can be cleanly reverted later — even after PoE has been
/// patched-and-relaunched by the user in between (we never assume any
/// state survives in memory).
///
/// Layout on disk:
///     &lt;Content.ggpk dir&gt;/backups/
///         &lt;patch-name&gt;/
///             &lt;sanitized internal path&gt;.bin
///             &lt;sanitized internal path&gt;.bin
///             ...
///
/// We store backups OUTSIDE the GGPK on purpose — keeping them inside
/// would defeat the goal (you'd lose them the moment GGG ships a patch
/// that rewrites the bundle).
/// </summary>
internal sealed class BackupManager
{
    private readonly string _root;

    /// <summary>
    /// Root directory where per-patch backups live. Exposed so the
    /// orchestrator can stash extra defense-in-depth artefacts
    /// (e.g. a verbatim copy of _.index.bin) next to the per-file
    /// backups.
    /// </summary>
    public string RootDirectory => _root;

    public BackupManager(string ggpkPath)
    {
        var dir = Path.GetDirectoryName(Path.GetFullPath(ggpkPath))
                  ?? throw new ArgumentException("ggpk path has no directory");
        _root = Path.Combine(dir, "backups");
    }

    public bool HasBackupsFor(string patchName)
        => Directory.Exists(Path.Combine(_root, patchName));

    public void Save(string patchName, string internalPath, ReadOnlySpan<byte> bytes)
    {
        string dst = PathFor(patchName, internalPath);
        Directory.CreateDirectory(Path.GetDirectoryName(dst)!);
        // Don't overwrite an existing backup — that would clobber the
        // pristine version with the already-patched bytes if the user
        // re-applies without reverting first.
        if (File.Exists(dst)) return;
        File.WriteAllBytes(dst, bytes.ToArray());
    }

    public byte[] Load(string patchName, string internalPath)
    {
        string src = PathFor(patchName, internalPath);
        if (!File.Exists(src))
            throw new FileNotFoundException($"No backup for {internalPath} under '{patchName}'", src);
        return File.ReadAllBytes(src);
    }

    public void Clear(string patchName)
    {
        var dir = Path.Combine(_root, patchName);
        if (Directory.Exists(dir)) Directory.Delete(dir, recursive: true);
    }

    private string PathFor(string patchName, string internalPath)
    {
        // Internal paths use '/' and may contain characters that are
        // valid on POSIX but reserved on NTFS (e.g. ':'). Sanitize by
        // replacing every reserved char with '_'.
        var sanitized = internalPath
            .Replace('/', Path.DirectorySeparatorChar);
        foreach (var c in Path.GetInvalidFileNameChars())
        {
            // Leave dir separators intact, replace everything else.
            if (c == Path.DirectorySeparatorChar) continue;
            sanitized = sanitized.Replace(c, '_');
        }
        return Path.Combine(_root, patchName, sanitized + ".bin");
    }
}
