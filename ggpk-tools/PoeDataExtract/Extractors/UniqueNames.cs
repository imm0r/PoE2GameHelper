using System.Text;
using LibBundle3;
using LibBundle3.Nodes;
using Index = LibBundle3.Index;

namespace PoeDataExtract.Extractors;

/// <summary>
/// Extracts <c>data/unique_item_name_map.tsv</c> (Metadata path → unique
/// item display name, e.g. "Metadata/Items/Charms/CharmOne1" →
/// "Valako's Roar").
///
/// PoE2 has no single <c>UniqueItems.datc64</c> table — instead the
/// mapping requires a four-way join across:
///   <list type="bullet">
///     <item><c>data/balance/uniquestashlayout.datc64</c>
///           → (WordsKey, ItemVisualIdentityKey) pairs</item>
///     <item><c>data/balance/words.datc64</c>
///           → row index → display string (wordlist=6 are uniques)</item>
///     <item><c>data/balance/baseitemtypes.datc64</c>
///           → (Id, ItemVisualIdentity) per base</item>
///     <item><c>data/balance/itemvisualidentity.datc64</c>
///           → connects BaseItemType.IVI to UniqueStashLayout.IVI when
///             the keys aren't directly equal (different in PoE2 0.x
///             where the join goes via the art path)</item>
///   </list>
///
/// Reference implementation: <c>Tools/explore_unique_names.py</c> — that
/// Python script demonstrated the join end-to-end and is the source of
/// truth for the column offsets.
///
/// CURRENT STATUS — placeholder. This extractor is wired into the verb
/// dispatcher but the actual join logic still requires:
///   <list type="number">
///     <item>schema lookups for the column offsets of each of the four
///           tables (WordsKey + IVI in USL, Id + IVI in BIT, text + wordlist
///           in Words, Id + DDSFile in ItemVisualIdentity)</item>
///     <item>u64 foreign-key read on DatReader (currently we only read
///           int32 / int64 string-ref values, not raw u64 FKs)</item>
///   </list>
/// Until that lands, keep using the legacy Python
/// <c>build_item_names_csv.py</c> pipeline for unique item names.
/// </summary>
internal sealed class UniqueNames : IExtractor
{
    public void Run(Index index, string outputTsvPath)
    {
        throw new NotImplementedException(
            "UniqueNames extractor is a placeholder. The join requires 4 tables + "
            + "u64 FK reads which DatReader doesn't expose yet. Use Tools/build_item_names_csv.py "
            + "for unique_item_name_map.tsv until this lands. See class doc for the design.");
    }
}
