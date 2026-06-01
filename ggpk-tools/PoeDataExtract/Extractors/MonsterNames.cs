using System.Text;
using LibBundle3;
using LibBundle3.Nodes;
using Index = LibBundle3.Index;

namespace PoeDataExtract.Extractors;

/// <summary>
/// Extracts <c>data/monster_name_map.tsv</c> from
/// <c>data/balance/monstervarieties.datc64</c>. Used at runtime by
/// TreeView_StatsFormatting to humanise monster metadata paths into
/// display names (e.g.
///   <c>Metadata/Monsters/Monkeys/MonkeyJunglePale</c> → "Pale Primate").
///
/// PoE2 0.x verified via dat-schema (poe-tool-dev/dat-schema):
///   rowSize = 974, auto-detected via the BB marker scan
///   @0x00   int64 string-ref → Id   (Metadata/Monsters/...)
///   @0x110  int64 string-ref → Name (display name)
///
/// Both refs use the legacy +8 encoding (DatReader.RowString handles
/// it transparently). Earlier attempts to guess Name's offset from
/// raw inspection landed on @0xF0 — that was wrong; the schema places
/// it at +272 (the @0xF0 column is actually some ModelName/AnimSet
/// field which happens to look name-shaped for a few rows).
///
/// Output TSV format:
///   metadata_path  display_name
///   Metadata/Monsters/Monkeys/MonkeyJungle      Jungle Primate
///   Metadata/Monsters/Monkeys/MonkeyJunglePale  Pale Primate
///   …
/// </summary>
internal sealed class MonsterNames : IExtractor
{
    private const int OffsetId   = 0x00;
    private const int OffsetName = 0x110;  // 272, per dat-schema

    public void Run(Index index, string outputTsvPath)
    {
        string[] candidates = { "data/balance/monstervarieties.datc64", "Data/MonsterVarieties.dat64" };
        FileNode? fileNode = null;
        foreach (var c in candidates)
        {
            if (index.TryFindNode(c, out var node) && node is FileNode fn) { fileNode = fn; break; }
        }
        if (fileNode is null)
            throw new FileNotFoundException(string.Join(" / ", candidates));

        var dat = new DatReader(fileNode.Record.Read().Span);
        Console.Out.WriteLine($"opened {candidates[0]}: rowCount={dat.RowCount} rowSize={dat.RowSize}");

        var sb = new StringBuilder(capacity: dat.RowCount * 80);
        sb.Append("metadata_path\tdisplay_name\n");
        int written = 0;
        for (int i = 0; i < dat.RowCount; i++)
        {
            string id   = dat.RowString(i, OffsetId);
            string name = dat.RowString(i, OffsetName);
            if (string.IsNullOrEmpty(id) && string.IsNullOrEmpty(name)) continue;
            // Defensive — tabs/newlines in display strings would wreck
            // the column count on the AHK side.
            name = name.Replace('\t', ' ').Replace('\n', ' ').Replace('\r', ' ');
            sb.Append(id).Append('\t').Append(name).Append('\n');
            written++;
        }

        WriteTsv(outputTsvPath, sb);
        Console.Out.WriteLine($"wrote {written} rows to {outputTsvPath}");
    }

    // Atomic write — write to .tmp, then move into place. Prevents the
    // helper from reloading half-written TSVs if extraction crashes
    // mid-run.
    private static void WriteTsv(string outputTsvPath, StringBuilder sb)
    {
        var dir = Path.GetDirectoryName(outputTsvPath);
        if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
        string tmp = outputTsvPath + ".tmp";
        File.WriteAllText(tmp, sb.ToString(), new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));
        if (File.Exists(outputTsvPath)) File.Delete(outputTsvPath);
        File.Move(tmp, outputTsvPath);
    }
}
