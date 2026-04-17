"""
Build stat description map from pre-extracted CSD files.

Requires: poe_data_tools to have already extracted CSD files via:
  poe_data_tools --patch 2 extract "Data/StatDescriptions/**/*.csd" --output <raw_dir>

The CSD files are UTF-16LE text config files containing stat→template mappings.
This script parses them and generates stat_desc_map.tsv.

Output TSV format (tab-separated):
  stat_id  TAB  template  TAB  arg_index  TAB  group_ids

Usage:
  python build_stat_desc_map_csv.py [extracted_dir] [output_tsv]

  extracted_dir = folder where poe_data_tools extracted files
                  (default: data/raw_extracted)
  output_tsv    = output path (default: data/stat_desc_map.tsv)
"""

import os
import re
import sys
import time
from pathlib import Path


# ---------------------------------------------------------------------------
# Template helpers
# ---------------------------------------------------------------------------
_WIKI_LINK_RE1 = re.compile(r"\[(?:[^\]|]+)\|([^\]]+)\]")  # [LinkText|Display] → Display
_WIKI_LINK_RE2 = re.compile(r"\[([^\]|]+)\]")               # [Text] → Text


def strip_wiki_links(text):
    text = _WIKI_LINK_RE1.sub(r"\1", text)
    text = _WIKI_LINK_RE2.sub(r"\1", text)
    return text


# ---------------------------------------------------------------------------
# CSD parser (same logic as original build_stat_desc_map.py)
# ---------------------------------------------------------------------------
def parse_csd(text):
    """
    Parse CSD format. Handles both format variants:

    Variant A (older, no lang blocks):
      description
      1 stat_id
      1|# "template with {0}"

    Variant B (newer, with lang blocks):
      description
      1 stat_id
      lang "English"
      1 "template with {0}"

    Multi-stat:
      description
      2 stat_id_min stat_id_max
      lang "English"
      1 "Adds {0} to {1} Fire Damage"

    Returns list of (stat_ids_tuple, template_string).
    """
    results = []
    lines = text.splitlines()
    n = len(lines)
    i = 0

    while i < n:
        if lines[i].strip() != "description":
            i += 1
            continue

        i += 1
        while i < n and not lines[i].strip():
            i += 1
        if i >= n:
            break

        stat_line = lines[i].strip()
        m = re.match(r"^(\d+)\s+(.+)$", stat_line)
        if not m:
            i += 1
            continue

        stat_ids = tuple(m.group(2).split())
        i += 1

        english_text = None
        found_any_lang = False
        in_english = False

        while i < n:
            s = lines[i].strip()

            if s == "description":
                break
            if s in ("no_description",):
                i += 1
                break
            if s.startswith("include "):
                i += 1
                continue

            lm = re.match(r'^lang\s+"([^"]+)"', s)
            if lm:
                found_any_lang = True
                in_english = lm.group(1).lower() == "english"
                i += 1
                continue

            if '"' in s:
                fq = s.index('"')
                lq = s.rindex('"')
                if fq < lq:
                    raw_template = s[fq + 1 : lq]
                    if english_text is None:
                        if in_english or not found_any_lang:
                            english_text = strip_wiki_links(raw_template)
                            if in_english:
                                i += 1
                                break

            i += 1

        if english_text is not None:
            results.append((stat_ids, english_text))

    return results


def decode_csd_file(file_path):
    """Read a CSD file, handling UTF-16LE with BOM or UTF-8 fallback."""
    with open(file_path, "rb") as f:
        data = f.read()

    if data[:2] == b"\xff\xfe":
        data = data[2:]
    try:
        return data.decode("utf-16-le", errors="replace")
    except Exception:
        return data.decode("utf-8", errors="replace")


# ---------------------------------------------------------------------------
# CSD file discovery (from extracted directory)
# ---------------------------------------------------------------------------
def collect_csd_files(extracted_dir):
    """Find all .csd files under the extracted StatDescriptions directory."""
    csd_dir = Path(extracted_dir)

    # poe_data_tools extracts to: <output>/Data/StatDescriptions/**/*.csd
    candidates = [
        csd_dir / "Data" / "StatDescriptions",
        csd_dir / "data" / "statdescriptions",
        csd_dir,
    ]

    csd_files = []
    for base in candidates:
        if base.is_dir():
            found = list(base.rglob("*.csd"))
            if found:
                csd_files = found
                print(f"  Found {len(csd_files)} CSD files under {base}")
                break

    if not csd_files:
        print(f"  WARNING: No .csd files found under {extracted_dir}")
        print("  Expected structure: <dir>/Data/StatDescriptions/**/*.csd")

    return sorted(csd_files)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main():
    script_dir = os.path.dirname(os.path.abspath(__file__))
    data_dir = os.path.join(os.path.dirname(script_dir), "data")

    extracted_dir = (
        sys.argv[1] if len(sys.argv) > 1 else os.path.join(data_dir, "raw_extracted")
    )
    output_tsv = (
        sys.argv[2]
        if len(sys.argv) > 2
        else os.path.join(data_dir, "stat_desc_map.tsv")
    )

    csd_files = collect_csd_files(extracted_dir)
    if not csd_files:
        print(f"ERROR: No CSD files found in {extracted_dir}")
        print()
        print("Extract them first with poe_data_tools:")
        print(
            '  poe_data_tools --patch 2 extract '
            '"Data/StatDescriptions/**/*.csd" '
            f'--output "{extracted_dir}"'
        )
        sys.exit(1)

    # Priority: stat_descriptions.csd first (most general), then specific files.
    # First-found wins for each stat_id.
    priority_first = [f for f in csd_files if f.name == "stat_descriptions.csd"]
    priority_rest = [f for f in csd_files if f not in priority_first]
    ordered = priority_first + priority_rest

    all_entries = {}  # stat_id → (template, arg_index, group_ids_tuple)
    total_parsed = 0

    print(f"\nParsing {len(ordered)} CSD files...")
    for csd_path in ordered:
        text = decode_csd_file(csd_path)
        entries = parse_csd(text)
        new_in_file = 0
        for stat_ids, template in entries:
            for idx, sid in enumerate(stat_ids):
                if sid not in all_entries:
                    all_entries[sid] = (template, idx, stat_ids)
                    new_in_file += 1
        total_parsed += len(entries)
        if new_in_file > 0:
            print(f"  {csd_path.name}: {len(entries)} blocks, {new_in_file} new stat_ids")

    print(f"\nTotal blocks parsed: {total_parsed}")
    print(f"Total unique stat_ids: {len(all_entries)}")

    # Add base_ aliases
    alias_added = 0
    for sid in list(all_entries.keys()):
        if sid.startswith("base_"):
            plain = sid[5:]
            if plain not in all_entries:
                all_entries[plain] = all_entries[sid]
                alias_added += 1
    print(f"Added {alias_added} base_* aliases")

    if not all_entries:
        print("ERROR: No stat descriptions found")
        sys.exit(1)

    # Write TSV
    os.makedirs(os.path.dirname(output_tsv), exist_ok=True)
    with open(output_tsv, "w", encoding="utf-8", newline="\n") as f:
        f.write("# stat_desc_map.tsv - generated by build_stat_desc_map_csv.py\n")
        f.write(f"# generated: {time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}\n")
        f.write("# Format: stat_id TAB template TAB arg_index TAB group_ids\n")
        f.write("# template placeholders: {0} {1} = stat values; wiki links stripped\n")
        f.write("# arg_index: which {N} this stat fills (0=first, 1=second, ...)\n")
        f.write("# group_ids: comma-separated group (multi-stat entries share a template)\n")
        for sid in sorted(all_entries):
            tmpl, idx, grp = all_entries[sid]
            group_str = ",".join(grp)
            f.write(f"{sid}\t{tmpl}\t{idx}\t{group_str}\n")

    print(f"\nWritten: {output_tsv} ({len(all_entries)} entries)")


if __name__ == "__main__":
    main()
