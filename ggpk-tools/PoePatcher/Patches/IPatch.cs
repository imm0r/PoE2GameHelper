using LibBundle3;
using Index = LibBundle3.Index;

namespace PoePatcher.Patches;

internal interface IPatch
{
    /// <summary>Stable lowercase identifier used on the CLI (<c>--patch &lt;name&gt;</c>).</summary>
    string Name { get; }

    /// <summary>Human-readable one-liner, shown by <c>poe-patcher list</c>.</summary>
    string Description { get; }

    /// <summary>
    /// Modify the GGPK / bundle index in place. Implementations MUST
    /// call <see cref="BackupManager.Save"/> for every file they touch
    /// BEFORE writing patched bytes, otherwise revert won't work.
    /// </summary>
    void Apply(Index index, BackupManager backups);

    /// <summary>Restore originals from the backup store.</summary>
    void Revert(Index index, BackupManager backups);
}
