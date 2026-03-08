#!/usr/bin/env python3
"""Build a RES .resbackup file from sorted source files.

Reads from RES_DATA_DIR (default: ~/Vault/Backups/librewolf):
  res-subreddits.txt  — one exact subreddit name per line
  res-wildcards.txt   — one wildcard/substring pattern per line
  res-other.json      — users, keywords, domains, flair, custom filters

Writes:
  reddit-enhancement-suite.resbackup  — importable RES backup
"""

import json
import os
import sys
from pathlib import Path

DATA_DIR = Path(os.environ.get("RES_DATA_DIR", Path.home() / "Vault/Backups/librewolf"))
BATCH_SIZE = 1000

def load_lines(filename):
    path = DATA_DIR / filename
    if not path.exists():
        print(f"Missing: {path}")
        sys.exit(1)
    lines = []
    for line in path.read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            lines.append(line)
    return lines

def build_wildcard_entry(patterns):
    """Single regex entry for substring/wildcard matching."""
    joined = "|".join(patterns)
    return [f"/({joined})/i"]

def build_exact_batches(names, batch_size=BATCH_SIZE):
    """Split exact subreddit names into batched regex entries."""
    entries = []
    for i in range(0, len(names), batch_size):
        batch = names[i : i + batch_size]
        joined = "|".join(batch)
        entries.append([f"/^({joined})$/i"])
    return entries

def main():
    if not DATA_DIR.exists():
        print(f"Data directory not found: {DATA_DIR}")
        print("Set RES_DATA_DIR or ensure the default path exists")
        sys.exit(1)

    subreddits = load_lines("res-subreddits.txt")
    wildcards = load_lines("res-wildcards.txt")

    other_path = DATA_DIR / "res-other.json"
    if not other_path.exists():
        print(f"Missing: {other_path}")
        sys.exit(1)
    other = json.loads(other_path.read_text())

    sub_entries = []
    sub_entries.append(build_wildcard_entry(wildcards))
    sub_entries.extend(build_exact_batches(subreddits))

    filte_reddit = {
        "subreddits": {"value": sub_entries},
        "users": other["users"],
        "keywords": other["keywords"],
        "domains": other["domains"],
        "flair": other["flair"],
        "excludeModqueue": {"value": False},
        "customFiltersP": other["customFiltersP"],
    }

    backup = {
        "SCHEMA_VERSION": 1,
        "data": {
            "RESoptions.filteReddit": filte_reddit,
        },
    }

    out_path = DATA_DIR / "reddit-enhancement-suite.resbackup"
    out_path.write_text(json.dumps(backup))

    total_entries = len(sub_entries)
    print(f"Subreddits: {len(subreddits)} names → {len(sub_entries) - 1} exact-match batches")
    print(f"Wildcards:  {len(wildcards)} patterns → 1 entry")
    print(f"Total subreddit filter entries: {total_entries}")
    print(f"Users: {len(other['users']['value'])}, Domains: {len(other['domains']['value'])}")
    print(f"Keywords: {len(other['keywords']['value'])}, Flair: {len(other['flair']['value'])}")
    print(f"Wrote: {out_path}")

if __name__ == "__main__":
    main()
