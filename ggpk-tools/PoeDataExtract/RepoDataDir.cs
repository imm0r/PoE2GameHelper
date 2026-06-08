namespace PoeDataExtract;

/// <summary>
/// Locates the PoEformance repo's <c>data/</c> folder so the bare-path /
/// extract-all convenience form can write the helper's TSVs straight into
/// it without the caller spelling out <c>--output-dir</c>.
/// </summary>
internal static class RepoDataDir
{
    /// <summary>
    /// Walks up from the executable location (then the working directory)
    /// looking for a repo marker — the entry-point script, or a
    /// <c>data/</c> + <c>ggpk-tools/</c> pair — and returns that repo's
    /// <c>data/</c> path. Falls back to <c>&lt;exeDir&gt;/data</c> so a
    /// standalone copy of the exe still writes somewhere predictable.
    /// Always returns a path; creates nothing.
    /// </summary>
    public static string Resolve()
    {
        foreach (var start in new[] { AppContext.BaseDirectory, Environment.CurrentDirectory })
        {
            var dir = new DirectoryInfo(start);
            while (dir is not null)
            {
                if (IsRepoRoot(dir.FullName))
                    return Path.Combine(dir.FullName, "data");
                dir = dir.Parent;
            }
        }
        return Path.Combine(AppContext.BaseDirectory, "data");
    }

    private static bool IsRepoRoot(string dir) =>
        File.Exists(Path.Combine(dir, "InGameStateMonitor.ahk"))
        || (Directory.Exists(Path.Combine(dir, "data"))
            && Directory.Exists(Path.Combine(dir, "ggpk-tools")));
}
