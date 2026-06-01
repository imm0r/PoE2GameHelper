using LibBundle3;
using Index = LibBundle3.Index;

namespace PoeDataExtract.Extractors;

/// <summary>
/// One extractor per logical table. Lives in its own class so the schema
/// (row size + column offsets) stays adjacent to the parsing code.
/// </summary>
internal interface IExtractor
{
    void Run(Index index, string outputTsvPath);
}
