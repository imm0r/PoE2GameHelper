using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;

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
///   2. Auto-scan local Steam game installs for an <c>oo2core*.dll</c> and
///      copy it next to the exe as <c>oo2core.dll</c> (the name
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

    // ─────────────────────────────────────────────────────────────────
    //  Local game scan
    // ─────────────────────────────────────────────────────────────────

    /// <summary>
    /// Returns the first <c>oo2core*.dll</c> found across the user's Steam
    /// libraries, or null. The scan is bounded (one directory level per
    /// game plus a handful of well-known subdirs) so it stays fast even on
    /// libraries with hundreds of GB of games.
    /// </summary>
    private static string? FindLocalOodle(string? ggpkHint)
    {
        foreach (var lib in SteamLibraries(ggpkHint))
            foreach (var dll in ScanLibrary(lib))
                return dll;
        return null;
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
    /// Yields every <c>oo2core*.dll</c> directly inside a game's root or one
    /// of a fixed set of common native-library subdirectories. Non-recursive
    /// per directory to keep the scan cheap.
    /// </summary>
    private static IEnumerable<string> ScanLibrary(string lib)
    {
        string common = Path.Combine(lib, "steamapps", "common");
        if (!Directory.Exists(common)) yield break;

        // Common spots where Oodle-using games keep oo2core_*.dll. The empty
        // string is the game root (where Path of Exile 1 keeps it).
        string[] subs =
        {
            "", "bin", @"bin\x64", "x64", "Win64", "Tools",
            @"Binaries\Win64", @"Engine\Binaries\Win64",
            @"Engine\Binaries\ThirdParty\Oodle\Win64",
            "Redist", "redist",
        };

        IEnumerable<string> games;
        try { games = Directory.EnumerateDirectories(common); }
        catch { yield break; }

        foreach (var game in games)
        {
            foreach (var sub in subs)
            {
                string dir = sub.Length == 0 ? game : Path.Combine(game, sub);
                if (!Directory.Exists(dir)) continue;
                string[] hits;
                try { hits = Directory.GetFiles(dir, "oo2core*.dll"); }
                catch { continue; }
                foreach (var h in hits) yield return h;
            }
        }
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
