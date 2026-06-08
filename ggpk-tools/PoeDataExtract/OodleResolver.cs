using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Text;

namespace PoeDataExtract;

/// <summary>
/// Makes the proprietary Oodle native library (oo2core) available next to
/// the executable before any bundle is touched. We can neither bundle nor
/// redistribute the DLL (it's closed-source RAD/Epic), so instead we copy
/// it from a game the user already owns on their own machine — the file
/// never crosses a distribution boundary we control.
///
/// Resolution order (all best-effort, never aborts the process):
///   1. Probe via the real OS loader (NativeLibrary.TryLoad) — covers the
///      exe dir, working dir, System32 and PATH. If already resolvable,
///      do nothing.
///   1b. Rename a versioned <c>oo2core_*win64.dll</c> dropped next to the
///      exe to the canonical <c>oo2core.dll</c>.
///   2. Auto-scan local game installs — Steam, Epic, plus generic game
///      containers across every fixed drive (covers Battle.net / GOG /
///      standalone) — for an <c>oo2core*.dll</c>, preferring the Oodle 2.9
///      <c>oo2core_9_win64.dll</c> (the version LibBundle3 is built for),
///      and copy it next to the exe as <c>oo2core.dll</c> (the name
///      <c>DllImport("oo2core")</c> in LibBundle3 resolves to).
///   3. Interactive file picker — only when stdio isn't redirected and the
///      caller allows it, so the AHK shell-out flow never pops a dialog.
/// </summary>
internal static class OodleResolver
{
    // LibBundle3 imports the codec via DllImport("oo2core"), so the Windows
    // loader looks for exactly this filename. Whatever versioned name the
    // source game uses (e.g. oo2core_9_win64.dll), we copy it to this.
    private const string TargetFileName = "oo2core.dll";

    /// <summary>
    /// Ensures oo2core is loadable. <paramref name="ggpkHint"/> is the
    /// user-supplied ggpk/index path — used to anchor the Steam-library
    /// scan on the right drive. <paramref name="allowPrompt"/> gates the
    /// interactive file-picker fallback. Returns true when Oodle is
    /// available (already or freshly provisioned); false otherwise — the
    /// caller still tries to open the bundle, which surfaces the existing
    /// guidance on failure.
    /// </summary>
    public static bool EnsureAvailable(string? ggpkHint, bool allowPrompt)
    {
        // 1. Already resolvable anywhere on the loader search path?
        try
        {
            if (NativeLibrary.TryLoad("oo2core", out var handle))
            {
                NativeLibrary.Free(handle);
                return true;
            }
        }
        catch { /* fall through to provisioning */ }

        // 1b. A versioned oo2core_*.dll already dropped next to the exe (or in
        //     the working dir)? Rename it to oo2core.dll — the name the loader
        //     actually wants — so the user doesn't have to do it by hand.
        if (TryAdoptLocalVersioned()) return true;

        string target = Path.Combine(AppContext.BaseDirectory, TargetFileName);

        // 2. Auto-scan local game installs.
        string? source = FindLocalOodle(ggpkHint);
        if (source is not null && TryCopy(source, target))
        {
            Console.Out.WriteLine($"oo2core.dll provisioned from {source}");
            return true;
        }

        // 3. Interactive fallback (manual CLI use only).
        if (allowPrompt)
        {
            string? picked = PromptForDll();
            if (picked is not null && TryCopy(picked, target))
            {
                Console.Out.WriteLine($"oo2core.dll provisioned from {picked}");
                return true;
            }
        }

        Console.Error.WriteLine(
            "oo2core (Oodle) DLL not found and could not be auto-located.\n" +
            "  Copy 'oo2core_9_win64.dll' from a game you own (e.g. a Path of Exile 1\n" +
            "  install root, or any other Oodle game) next to this executable and\n" +
            "  rename the copy to 'oo2core.dll'.");
        return false;
    }

    /// <summary>
    /// If a versioned Oodle DLL (e.g. <c>oo2core_9_win64.dll</c>) is sitting
    /// next to the executable or in the working directory but the canonical
    /// <c>oo2core.dll</c> isn't loadable, rename it in place to
    /// <c>oo2core.dll</c>. The loader imports <c>DllImport("oo2core")</c> →
    /// <c>oo2core.dll</c>, so the versioned filename alone is never picked up.
    /// Falls back to a copy if the move is blocked. Returns true on success.
    /// </summary>
    private static bool TryAdoptLocalVersioned()
    {
        // Search the exe dir and the working dir (both on the loader's path),
        // de-duplicated so the same folder isn't processed twice.
        var dirs = new List<string>();
        foreach (var d in new[] { AppContext.BaseDirectory, Environment.CurrentDirectory })
        {
            if (string.IsNullOrEmpty(d)) continue;
            string full = Path.GetFullPath(d).TrimEnd('\\', '/');
            if (!dirs.Any(x => string.Equals(x, full, StringComparison.OrdinalIgnoreCase)))
                dirs.Add(full);
        }

        foreach (var dir in dirs)
        {
            string[] hits;
            try { hits = Directory.GetFiles(dir, "oo2core*.dll"); }
            catch { continue; }
            // Prefer the Oodle 2.9 oo2core_9_win64.dll if several are present.
            foreach (var src in hits.OrderByDescending(IsPreferredOodle))
            {
                // Skip the canonical name itself — it either already works
                // (then we wouldn't be here) or is a broken file we shouldn't
                // move onto itself.
                if (string.Equals(Path.GetFileName(src), TargetFileName, StringComparison.OrdinalIgnoreCase))
                    continue;

                string dst = Path.Combine(dir, TargetFileName);
                try
                {
                    File.Move(src, dst, overwrite: true);
                    Console.Out.WriteLine($"Renamed {Path.GetFileName(src)} → {TargetFileName}");
                    return true;
                }
                catch (Exception ex)
                {
                    // Move can fail (locked / cross-volume) — copy so we still
                    // end up with a usable oo2core.dll.
                    try
                    {
                        File.Copy(src, dst, overwrite: true);
                        Console.Out.WriteLine($"Copied {Path.GetFileName(src)} → {TargetFileName}");
                        return true;
                    }
                    catch
                    {
                        Console.Error.WriteLine(
                            $"Found {src} but couldn't rename it to {TargetFileName}: {ex.Message}");
                    }
                }
            }
        }
        return false;
    }

    // ─────────────────────────────────────────────────────────────────
    //  Local game scan
    // ─────────────────────────────────────────────────────────────────

    /// <summary>
    /// Returns an <c>oo2core*.dll</c> found in a local game install, or null.
    /// Searches Steam libraries, Epic install locations and generic game
    /// containers across every fixed drive. Returns the first
    /// <c>oo2core_9_win64.dll</c> (Oodle 2.9 — what LibBundle3 targets) as
    /// soon as one is seen; only if none exists does it fall back to any
    /// other <c>oo2core*.dll</c>. The scan is bounded (one directory level
    /// per game plus a handful of well-known subdirs) so it stays fast.
    /// </summary>
    private static string? FindLocalOodle(string? ggpkHint)
    {
        string? fallback = null;
        foreach (var game in GameDirectories(ggpkHint))
        {
            foreach (var dll in ScanGameDir(game))
            {
                if (IsPreferredOodle(dll)) return dll; // Oodle 2.9 — take it
                fallback ??= dll;                      // remember a non-2.9 hit
            }
        }
        return fallback;
    }

    // oo2core_9_win64.dll == Oodle 2.9, the line PoE/PoE2 use and LibBundle3
    // is built against. Prefer it over any other oo2core variant.
    private static bool IsPreferredOodle(string path) =>
        Path.GetFileName(path).StartsWith("oo2core_9", StringComparison.OrdinalIgnoreCase);

    /// <summary>
    /// Enumerates candidate game directories from every source: Steam
    /// (library\steamapps\common\*), Epic (exact install locations from the
    /// launcher manifests), and a generic sweep of common game containers on
    /// each fixed drive — drive root, Program Files, Program Files (x86)
    /// (Battle.net's default), Games, Epic Games, GOG Games, Riot Games,
    /// XboxGames. De-duplicated; obvious system folders are skipped.
    /// </summary>
    private static IEnumerable<string> GameDirectories(string? ggpkHint)
    {
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        bool IsNew(string dir, out string full)
        {
            full = "";
            if (string.IsNullOrEmpty(dir)) return false;
            try { full = Path.GetFullPath(dir).TrimEnd('\\', '/'); } catch { return false; }
            return seen.Add(full);
        }

        // 1. Steam: every game under each library's common\ folder.
        foreach (var lib in SteamLibraries(ggpkHint))
            foreach (var game in SafeEnumDirs(Path.Combine(lib, "steamapps", "common")))
                if (IsNew(game, out var f)) yield return f;

        // 2. Epic: exact install locations parsed from the launcher manifests.
        foreach (var loc in EpicInstallLocations())
            if (IsNew(loc, out var f)) yield return f;

        // 3. Generic containers across all fixed drives.
        foreach (var drive in FixedDriveRoots())
        {
            string[] containers =
            {
                drive,                                       // H:\  → H:\Diablo IV
                Path.Combine(drive, "Program Files"),
                Path.Combine(drive, "Program Files (x86)"),  // Battle.net default
                Path.Combine(drive, "Games"),
                Path.Combine(drive, "Epic Games"),
                Path.Combine(drive, "GOG Games"),
                Path.Combine(drive, "Riot Games"),
                Path.Combine(drive, "XboxGames"),
            };
            foreach (var container in containers)
                foreach (var game in SafeEnumDirs(container))
                    if (!IsSystemDir(game) && IsNew(game, out var f)) yield return f;
        }
    }

    /// <summary>
    /// Yields every <c>oo2core*.dll</c> directly inside a game's root or one
    /// of a fixed set of common native-library subdirectories. Non-recursive
    /// per directory to keep the scan cheap.
    /// </summary>
    private static IEnumerable<string> ScanGameDir(string game)
    {
        // Common spots where Oodle-using games keep oo2core_*.dll. The empty
        // string is the game root (where Path of Exile 1 keeps it).
        string[] subs =
        {
            "", "bin", @"bin\x64", "x64", "Win64", "Tools",
            @"Binaries\Win64", @"Engine\Binaries\Win64",
            @"Engine\Binaries\ThirdParty\Oodle\Win64",
            "Redist", "redist",
        };

        foreach (var sub in subs)
        {
            string dir = sub.Length == 0 ? game : Path.Combine(game, sub);
            string[] hits;
            try { hits = Directory.Exists(dir) ? Directory.GetFiles(dir, "oo2core*.dll") : Array.Empty<string>(); }
            catch { continue; }
            foreach (var h in hits) yield return h;
        }
    }

    // Fixed (non-removable, ready) drive roots, e.g. "C:\", "H:\".
    private static IEnumerable<string> FixedDriveRoots()
    {
        DriveInfo[] drives;
        try { drives = DriveInfo.GetDrives(); }
        catch { yield break; }
        foreach (var d in drives)
        {
            bool ok;
            try { ok = d.DriveType == DriveType.Fixed && d.IsReady; }
            catch { ok = false; }
            if (ok) yield return d.RootDirectory.FullName;
        }
    }

    private static readonly HashSet<string> _systemDirs = new(StringComparer.OrdinalIgnoreCase)
    {
        "Windows", "Windows.old", "$Recycle.Bin", "System Volume Information",
        "Recovery", "PerfLogs", "ProgramData", "Users", "MSOCache",
        "Intel", "AMD", "NVIDIA", "$WinREAgent",
    };

    // Skip obvious non-game top-level folders so the drive-root sweep doesn't
    // wander into the system tree.
    private static bool IsSystemDir(string dir)
    {
        string name = Path.GetFileName(dir);
        return name.Length == 0 || _systemDirs.Contains(name);
    }

    /// <summary>
    /// Reads each Epic Games Launcher manifest (<c>*.item</c> under
    /// ProgramData) and yields the <c>InstallLocation</c> of every installed
    /// title — gives exact paths regardless of which drive they live on.
    /// </summary>
    private static IEnumerable<string> EpicInstallLocations()
    {
        string manifests = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
            "Epic", "EpicGamesLauncher", "Data", "Manifests");
        foreach (var item in SafeEnumFiles(manifests, "*.item"))
        {
            string? loc = ReadJsonStringField(item, "InstallLocation");
            if (!string.IsNullOrEmpty(loc)) yield return loc;
        }
    }

    // Pulls a single JSON string value out of a small manifest file without a
    // full JSON parser (keeps the AOT binary dependency-free). Honours \\ and
    // \" escapes in the value; returns null if the key isn't present.
    private static string? ReadJsonStringField(string file, string key)
    {
        string text;
        try { text = File.ReadAllText(file); } catch { return null; }

        int k = text.IndexOf("\"" + key + "\"", StringComparison.Ordinal);
        if (k < 0) return null;
        int colon = text.IndexOf(':', k);
        if (colon < 0) return null;
        int q = text.IndexOf('"', colon + 1);
        if (q < 0) return null;

        var sb = new StringBuilder();
        for (int j = q + 1; j < text.Length; j++)
        {
            char c = text[j];
            if (c == '\\' && j + 1 < text.Length) { sb.Append(text[++j]); continue; }
            if (c == '"') break;
            sb.Append(c);
        }
        return sb.ToString();
    }

    private static List<string> SafeEnumDirs(string path)
    {
        var list = new List<string>();
        if (!Directory.Exists(path)) return list;
        try { foreach (var d in Directory.EnumerateDirectories(path)) list.Add(d); }
        catch { /* partial result is fine */ }
        return list;
    }

    private static List<string> SafeEnumFiles(string path, string pattern)
    {
        var list = new List<string>();
        if (!Directory.Exists(path)) return list;
        try { foreach (var f in Directory.EnumerateFiles(path, pattern)) list.Add(f); }
        catch { /* partial result is fine */ }
        return list;
    }

    /// <summary>
    /// Enumerates distinct Steam library roots: anchored off the ggpk hint's
    /// drive, the default Steam install dirs, then everything listed in
    /// <c>libraryfolders.vdf</c>. Registry-free on purpose so the AOT binary
    /// carries no extra dependency.
    /// </summary>
    private static List<string> SteamLibraries(string? ggpkHint)
    {
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var roots = new List<string>();

        void AddLib(string? path)
        {
            if (string.IsNullOrEmpty(path)) return;
            path = path.TrimEnd('\\', '/');
            if (Directory.Exists(Path.Combine(path, "steamapps")) && seen.Add(path))
                roots.Add(path);
        }

        // 1. Derive the library from the ggpk hint (…\steamapps\common\<game>\…).
        if (!string.IsNullOrEmpty(ggpkHint))
        {
            int i = ggpkHint.IndexOf(@"\steamapps\", StringComparison.OrdinalIgnoreCase);
            if (i > 0) AddLib(ggpkHint.Substring(0, i));
        }

        // 2. Default Steam install locations.
        foreach (var pf in new[]
        {
            Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86),
            Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),
        })
            if (!string.IsNullOrEmpty(pf)) AddLib(Path.Combine(pf, "Steam"));

        // 3. Expand via libraryfolders.vdf of every root found so far.
        foreach (var root in roots.ToList())
        {
            var vdf = Path.Combine(root, "steamapps", "libraryfolders.vdf");
            if (File.Exists(vdf))
                foreach (var p in ParseVdfPaths(vdf)) AddLib(p);
        }

        return roots;
    }

    /// <summary>
    /// Pulls the <c>"path"  "&lt;dir&gt;"</c> values out of Steam's
    /// libraryfolders.vdf (KeyValues text). Paths are stored with doubled
    /// backslashes, which we unescape. Best-effort — returns whatever it
    /// parsed on any error.
    /// </summary>
    private static List<string> ParseVdfPaths(string vdfFile)
    {
        var outPaths = new List<string>();
        try
        {
            foreach (var line in File.ReadLines(vdfFile))
            {
                var toks = QuotedTokens(line);
                if (toks.Count >= 2 && toks[0].Equals("path", StringComparison.OrdinalIgnoreCase))
                    outPaths.Add(toks[1].Replace(@"\\", @"\"));
            }
        }
        catch { /* malformed/unreadable VDF — return what we have */ }
        return outPaths;
    }

    // Extracts the quote-delimited tokens from a single VDF line. Steam
    // never embeds literal quotes inside the path values we care about, so
    // a simple paired scan is enough.
    private static List<string> QuotedTokens(string line)
    {
        var list = new List<string>();
        int i = 0;
        while (true)
        {
            int s = line.IndexOf('"', i);
            if (s < 0) break;
            int e = line.IndexOf('"', s + 1);
            if (e < 0) break;
            list.Add(line.Substring(s + 1, e - s - 1));
            i = e + 1;
        }
        return list;
    }

    private static bool TryCopy(string src, string target)
    {
        try
        {
            var dir = Path.GetDirectoryName(target);
            if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
            File.Copy(src, target, overwrite: true);
            return true;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"Failed to copy Oodle DLL from {src}: {ex.Message}");
            return false;
        }
    }

    // ─────────────────────────────────────────────────────────────────
    //  Interactive file picker (comdlg32 GetOpenFileNameW)
    // ─────────────────────────────────────────────────────────────────

    /// <summary>
    /// Opens a native "open file" dialog so the user can point us at an
    /// oo2core DLL (or any DLL inside a game they own). Returns the chosen
    /// path, or null on cancel / failure. Pure P/Invoke — no WinForms — so
    /// it stays AOT-friendly.
    /// </summary>
    private static string? PromptForDll()
    {
        const int maxChars = 2048;
        nint fileBuf = Marshal.AllocHGlobal(maxChars * sizeof(char));
        nint filterBuf = Marshal.StringToHGlobalUni(
            "Oodle DLL (oo2core*.dll)\0oo2core*.dll\0All files (*.*)\0*.*\0\0");
        nint titleBuf = Marshal.StringToHGlobalUni(
            "Select oo2core (Oodle) DLL — e.g. from a Path of Exile 1 install");
        try
        {
            Marshal.WriteInt16(fileBuf, 0, 0); // empty initial filename

            var ofn = new OpenFileName
            {
                lStructSize = (uint)Unsafe.SizeOf<OpenFileName>(),
                lpstrFilter = filterBuf,
                lpstrFile = fileBuf,
                nMaxFile = maxChars,
                lpstrTitle = titleBuf,
                Flags = OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST | OFN_EXPLORER
                      | OFN_NOCHANGEDIR | OFN_HIDEREADONLY,
            };

            if (GetOpenFileNameW(ref ofn) != 0)
                return Marshal.PtrToStringUni(fileBuf);
            return null;
        }
        catch
        {
            return null;
        }
        finally
        {
            Marshal.FreeHGlobal(fileBuf);
            Marshal.FreeHGlobal(filterBuf);
            Marshal.FreeHGlobal(titleBuf);
        }
    }

    private const uint OFN_HIDEREADONLY = 0x00000004;
    private const uint OFN_NOCHANGEDIR  = 0x00000008;
    private const uint OFN_PATHMUSTEXIST = 0x00000800;
    private const uint OFN_FILEMUSTEXIST = 0x00001000;
    private const uint OFN_EXPLORER      = 0x00080000;

    // OPENFILENAMEW (Unicode) — all string fields kept as nint so the struct
    // is blittable and needs no marshalling (we manage the buffers manually).
    [StructLayout(LayoutKind.Sequential)]
    private struct OpenFileName
    {
        public uint lStructSize;
        public nint hwndOwner;
        public nint hInstance;
        public nint lpstrFilter;
        public nint lpstrCustomFilter;
        public uint nMaxCustFilter;
        public uint nFilterIndex;
        public nint lpstrFile;
        public uint nMaxFile;
        public nint lpstrFileTitle;
        public uint nMaxFileTitle;
        public nint lpstrInitialDir;
        public nint lpstrTitle;
        public uint Flags;
        public ushort nFileOffset;
        public ushort nFileExtension;
        public nint lpstrDefExt;
        public nint lCustData;
        public nint lpfnHook;
        public nint lpTemplateName;
        public nint pvReserved;
        public uint dwReserved;
        public uint FlagsEx;
    }

#pragma warning disable SYSLIB1054 // blittable signature; explicit P/Invoke is fine here
    [DllImport("comdlg32.dll", SetLastError = true)]
    private static extern int GetOpenFileNameW(ref OpenFileName ofn);
#pragma warning restore SYSLIB1054
}
