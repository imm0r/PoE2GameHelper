"""
Build a complete item name dictionary from pre-dumped CSVs.

Requires: poe_data_tools to have already exported all CSVs via dump_tables.bat

Extracts and joins:
  - Words.csv            → tier word names + unique names (Wordlist 6)
  - ModType.csv          → tier-word array references
  - Mods.csv             → mod prefix/suffix names + tier words (via ModType + Words)
  - BaseItemTypes.csv    → base item names
  - UniqueGoldPrices.csv → unique item gold prices
  - UniqueStashLayout.csv + ItemVisualIdentity.csv → metadata_path→unique_name

Output files (same format as original build_item_names.py):
  mod_name_map.tsv         → mod_id  name  gen_type  tier_word
  base_item_name_map.tsv   → metadata_path  display_name
  unique_name_map.tsv      → unique_name  gold_price
  unique_item_name_map.tsv → metadata_path  unique_name

Usage:
  python build_item_names_csv.py [csv_dir]
"""

import csv
import os
import re
import sys
import time


def read_csv(csv_dir, table_name, required_cols=None):
    """Read a CSV and return list of row dicts. Validates required columns."""
    path = os.path.join(csv_dir, f"{table_name}.csv")
    if not os.path.isfile(path):
        print(f"  WARNING: {path} not found")
        return []

    with open(path, "r", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        if required_cols:
            missing = set(required_cols) - set(reader.fieldnames or [])
            if missing:
                print(f"  WARNING: {table_name}.csv missing columns: {missing}")
                print(f"  Available: {reader.fieldnames[:20]}")
        rows = list(reader)

    print(f"  {table_name}.csv: {len(rows):,} rows")
    return rows


def safe_int(val, default=0):
    """Parse an int from CSV value, handling empty strings and floats."""
    if not val or val == "":
        return default
    try:
        return int(val)
    except ValueError:
        try:
            return int(float(val))
        except ValueError:
            return default


def parse_array_field(val):
    """Parse a poe_data_tools array field like '[1, 2, 3]' into list of ints."""
    if not val or val in ("", "[]"):
        return []
    val = val.strip("[] ")
    if not val:
        return []
    result = []
    for item in val.split(","):
        item = item.strip()
        if item:
            try:
                result.append(int(item))
            except ValueError:
                try:
                    result.append(int(float(item)))
                except ValueError:
                    pass
    return result


# ---------------------------------------------------------------------------
# 1. Words extraction
# ---------------------------------------------------------------------------
def extract_words(csv_dir):
    """Returns {row_index: {'wordlist': id, 'text': str}}"""
    print("\n--- Words ---")
    rows = read_csv(csv_dir, "Words", ["Wordlist", "Text"])
    words = {}
    for i, row in enumerate(rows):
        wordlist_id = safe_int(row.get("Wordlist", ""), -1)
        text = row.get("Text", "").strip()
        words[i] = {"wordlist": wordlist_id, "text": text}

    wl6_count = sum(1 for v in words.values() if v["wordlist"] == 6)
    print(f"  Wordlist 6 (unique names): {wl6_count} entries")
    return words


# ---------------------------------------------------------------------------
# 2. ModType → Words mapping
# ---------------------------------------------------------------------------
def extract_mod_type_words(csv_dir, words_count):
    """Returns {row_index: [word_row_indices]}"""
    print("\n--- ModType ---")
    rows = read_csv(csv_dir, "ModType")
    if not rows:
        return {}

    # Find the unnamed array column that contains word references.
    # In poe_data_tools CSV, unnamed columns may appear as column_2, column_3, etc.
    # or the tier-word array might be a named column.
    # We try all array-like columns and pick the one with valid word indices.
    array_col = None
    for col_name in (rows[0].keys() if rows else []):
        # Check if this column contains array data
        sample_vals = [r.get(col_name, "") for r in rows[:50]]
        array_vals = [v for v in sample_vals if v.startswith("[")]
        if len(array_vals) > 5:
            # Check if parsed values are valid word indices
            valid = 0
            for v in array_vals[:20]:
                indices = parse_array_field(v)
                if indices and all(0 <= idx < words_count for idx in indices):
                    valid += 1
            if valid > 0 and (array_col is None):
                array_col = col_name
                print(f"  Using column '{col_name}' as tier-word array ({valid} valid samples)")

    result = {}
    for i, row in enumerate(rows):
        if array_col:
            indices = parse_array_field(row.get(array_col, ""))
            result[i] = [idx for idx in indices if idx < words_count]
        else:
            result[i] = []

    with_words = sum(1 for v in result.values() if v)
    print(f"  {len(result)} ModType rows, {with_words} with word references")
    return result


# ---------------------------------------------------------------------------
# 3. Mods extraction
# ---------------------------------------------------------------------------
def extract_mods(csv_dir, words, modtype_words):
    """Returns list of (mod_id, name, gen_type, tier_word)."""
    print("\n--- Mods ---")
    rows = read_csv(csv_dir, "Mods", ["Id", "Name", "GenerationType", "ModType"])
    if not rows:
        return []

    modtype_count = max(modtype_words.keys()) + 1 if modtype_words else 0

    results = []
    for row in rows:
        mod_id = row.get("Id", "").strip()
        if not mod_id:
            continue

        name = row.get("Name", "").strip()
        gen_type = safe_int(row.get("GenerationType", ""), 0)

        # ModType is a foreignrow → integer index
        modtype_row = safe_int(row.get("ModType", ""), -1)

        tier_word = ""
        if 0 <= modtype_row < modtype_count and modtype_row in modtype_words:
            for widx in modtype_words[modtype_row]:
                entry = words.get(widx, {})
                wl = entry.get("wordlist", -1)
                text = entry.get("text", "")
                if text and wl in (1, 3, 7) and not tier_word:
                    tier_word = text

        results.append((mod_id, name, gen_type, tier_word))

    with_name = sum(1 for _, n, _, _ in results if n)
    with_tier = sum(1 for _, _, _, t in results if t)
    print(f"  {len(results)} mods, {with_name} with name, {with_tier} with tier word")
    return results


# ---------------------------------------------------------------------------
# 4. Base item types
# ---------------------------------------------------------------------------
def extract_base_items(csv_dir):
    """Returns list of (metadata_path, display_name)."""
    print("\n--- BaseItemTypes ---")
    rows = read_csv(csv_dir, "BaseItemTypes", ["Id", "Name"])
    if not rows:
        return []

    results = []
    for row in rows:
        item_id = row.get("Id", "").strip()
        if not item_id:
            continue
        name = row.get("Name", "").strip()
        results.append((item_id, name))

    print(f"  {len(results)} base items")
    return results


# ---------------------------------------------------------------------------
# 5. Unique names from Words Wordlist 6 + UniqueGoldPrices
# ---------------------------------------------------------------------------
def extract_unique_gold_prices(csv_dir, words):
    """Returns list of (unique_name, gold_price)."""
    print("\n--- UniqueGoldPrices ---")
    rows = read_csv(csv_dir, "UniqueGoldPrices")
    if not rows:
        return []

    results = []
    for row in rows:
        # Name is a foreignrow → Words index
        words_row = safe_int(row.get("Name", ""), -1)
        price = safe_int(row.get("Price", ""), 0)
        entry = words.get(words_row, {})
        name = entry.get("text", "") if isinstance(entry, dict) else ""
        if name:
            results.append((name, price))

    print(f"  {len(results)} unique gold prices")
    return results


# ---------------------------------------------------------------------------
# 5b. Unique item names (metadata_path → unique_name)
#     Join: UniqueStashLayout + ItemVisualIdentity + BaseItemTypes
# ---------------------------------------------------------------------------
def ivi_match_key(ivi_id_str):
    """Generate a fuzzy match key from an ItemVisualIdentity Id string."""
    parts = re.findall(r"[A-Z][a-z0-9]*|[0-9]+", ivi_id_str)
    num = next((p for p in parts if p.isdigit()), "")
    rest = tuple(sorted(p for p in parts if p not in ("Four", "Unique") and not p.isdigit()))
    return (rest, num)


def extract_unique_item_names(csv_dir, words):
    """Returns list of (metadata_path, unique_name)."""
    print("\n--- Unique item name map (USL + IVI + BIT) ---")

    # Load ItemVisualIdentity → build row→match_key
    ivi_rows = read_csv(csv_dir, "ItemVisualIdentity", ["Id"])
    if not ivi_rows:
        return []
    ivi_row_to_key = {}
    for i, row in enumerate(ivi_rows):
        ivi_id = row.get("Id", "").strip()
        if ivi_id:
            ivi_row_to_key[i] = ivi_match_key(ivi_id)

    # Load UniqueStashLayout → build match_key → unique_name
    usl_rows = read_csv(csv_dir, "UniqueStashLayout", ["WordsKey", "ItemVisualIdentityKey"])
    if not usl_rows:
        return []

    key_to_unique = {}
    for row in usl_rows:
        words_row = safe_int(row.get("WordsKey", ""), -1)
        ivi_row = safe_int(row.get("ItemVisualIdentityKey", ""), -1)
        is_alt = row.get("IsAlternateArt", "").strip().lower() in ("true", "1")

        entry = words.get(words_row, {})
        name = entry.get("text", "") if isinstance(entry, dict) else ""
        if not name or ivi_row not in ivi_row_to_key:
            continue

        key = ivi_row_to_key[ivi_row]
        existing = key_to_unique.get(key)
        if existing is None or (not is_alt and existing[1]):
            key_to_unique[key] = (name, is_alt)

    print(f"  {len(key_to_unique)} unique match keys")

    # Load BaseItemTypes → join via IVI match_key
    bit_rows = read_csv(csv_dir, "BaseItemTypes", ["Id", "ItemVisualIdentity"])
    if not bit_rows:
        return []

    results = []
    for row in bit_rows:
        item_id = row.get("Id", "").strip()
        if not item_id:
            continue
        ivi_row = safe_int(row.get("ItemVisualIdentity", ""), -1)
        if ivi_row not in ivi_row_to_key:
            continue
        key = ivi_row_to_key[ivi_row]
        match = key_to_unique.get(key)
        if match:
            results.append((item_id, match[0]))

    print(f"  Mapped {len(results)} base item paths to unique names")
    return results


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main():
    script_dir = os.path.dirname(os.path.abspath(__file__))
    data_dir = os.path.join(os.path.dirname(script_dir), "data")

    csv_dir = sys.argv[1] if len(sys.argv) > 1 else os.path.join(data_dir, "raw_csv", "data", "balance")

    # Check that at least one expected CSV exists
    test_csv = os.path.join(csv_dir, "Words.csv")
    if not os.path.isfile(test_csv):
        print(f"ERROR: CSV directory not populated: {csv_dir}")
        print()
        print("Run dump_tables.bat first to generate CSVs from game data.")
        sys.exit(1)

    # Step 1: Words
    words = extract_words(csv_dir)

    # Step 2: ModType → Words mapping
    modtype_words = extract_mod_type_words(csv_dir, len(words))

    # Step 3: Mods
    mods = extract_mods(csv_dir, words, modtype_words)

    # Write mod_name_map.tsv
    mod_tsv = os.path.join(data_dir, "mod_name_map.tsv")
    with open(mod_tsv, "w", encoding="utf-8", newline="\n") as f:
        f.write("# mod_name_map.tsv - generated by build_item_names_csv.py\n")
        f.write(f"# generated: {time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}\n")
        f.write("# columns: mod_id\tname\tgen_type(1=Prefix,2=Suffix,3=Unique)\ttier_word\n")
        for mod_id, name, gen_type, tier_word in mods:
            f.write(f"{mod_id}\t{name}\t{gen_type}\t{tier_word}\n")
    print(f"\nWritten: {mod_tsv} ({len(mods)} entries)")

    # Step 4: Base item types
    base_items = extract_base_items(csv_dir)
    base_tsv = os.path.join(data_dir, "base_item_name_map.tsv")
    with open(base_tsv, "w", encoding="utf-8", newline="\n") as f:
        f.write("# base_item_name_map.tsv - generated by build_item_names_csv.py\n")
        f.write(f"# generated: {time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}\n")
        f.write("# columns: metadata_path\tdisplay_name\n")
        for item_id, name in base_items:
            f.write(f"{item_id}\t{name}\n")
    print(f"Written: {base_tsv} ({len(base_items)} entries)")

    # Step 5: Unique names (all Words Wordlist 6)
    unique_names_all = sorted(
        {v["text"] for v in words.values() if v.get("wordlist") == 6 and v.get("text")}
    )

    # Enrich with gold prices
    unique_gold = extract_unique_gold_prices(csv_dir, words)
    gold_map = {name: price for name, price in unique_gold}

    unique_tsv = os.path.join(data_dir, "unique_name_map.tsv")
    with open(unique_tsv, "w", encoding="utf-8", newline="\n") as f:
        f.write("# unique_name_map.tsv - generated by build_item_names_csv.py\n")
        f.write(f"# generated: {time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}\n")
        f.write("# Source: Words.csv Wordlist 6 (all PoE2 unique names)\n")
        f.write("# columns: unique_name\tgold_price\n")
        for name in unique_names_all:
            price = gold_map.get(name, "")
            f.write(f"{name}\t{price}\n")
    print(f"Written: {unique_tsv} ({len(unique_names_all)} unique names)")

    # Step 5b: Unique item names (metadata_path → unique_name)
    unique_items = extract_unique_item_names(csv_dir, words)
    unique_item_tsv = os.path.join(data_dir, "unique_item_name_map.tsv")
    with open(unique_item_tsv, "w", encoding="utf-8", newline="\n") as f:
        f.write("# unique_item_name_map.tsv - generated by build_item_names_csv.py\n")
        f.write(f"# generated: {time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}\n")
        f.write("# columns: metadata_path\tunique_name\n")
        for item_id, unique_name in unique_items:
            f.write(f"{item_id}\t{unique_name}\n")
    print(f"Written: {unique_item_tsv} ({len(unique_items)} entries)")

    print("\nDone! Files written:")
    print(f"  {mod_tsv}")
    print(f"  {base_tsv}")
    print(f"  {unique_tsv}")
    print(f"  {unique_item_tsv}")


if __name__ == "__main__":
    main()
