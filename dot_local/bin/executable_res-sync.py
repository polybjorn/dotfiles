#!/usr/bin/env python3
"""Sync manual RES filter additions back into source files.

Usage:
  1. Export a fresh .resbackup from RES (Settings > Backup & Restore > Backup)
  2. Save it as 'import.resbackup' in RES_DATA_DIR (default: ~/Vault/Backups/librewolf)
  3. Run: res-sync.py
  4. Review changes, then run: res-build.py

Merges new subreddits, users, domains, keywords, flair, and custom filters
from the RES export into the source files without losing existing entries.
"""

import json
import os
import sys
from pathlib import Path

DATA_DIR = Path(os.environ.get("RES_DATA_DIR", Path.home() / "Vault/Backups/librewolf"))
IMPORT_FILE = DATA_DIR / "import.resbackup"

def load_lines(filename):
    path = DATA_DIR / filename
    if not path.exists():
        return set()
    return set(
        l.strip().lower()
        for l in path.read_text().splitlines()
        if l.strip() and not l.startswith("#")
    )

def save_lines(filename, lines):
    path = DATA_DIR / filename
    sorted_lines = sorted(lines, key=str.lower)
    path.write_text("\n".join(sorted_lines) + "\n")

def extract_plain_subs(entries):
    """Extract plain subreddit names from RES filter entries."""
    plain = set()
    for entry in entries:
        name = entry[0] if isinstance(entry, list) else entry
        if not name.startswith("/"):
            plain.add(name.lower())
    return plain

def main():
    if not IMPORT_FILE.exists():
        print(f"Missing: {IMPORT_FILE}")
        print("Export a .resbackup from RES and save it as 'import.resbackup'")
        sys.exit(1)

    import_data = json.loads(IMPORT_FILE.read_text())
    fr = import_data["data"].get("RESoptions.filteReddit", {})

    if not fr:
        print("No filteReddit data found in import file")
        sys.exit(1)

    current_subs = load_lines("res-subreddits.txt")
    current_wildcards = load_lines("res-wildcards.txt")

    other_path = DATA_DIR / "res-other.json"
    current_other = json.loads(other_path.read_text())

    # --- Sync subreddits ---
    import_subs = extract_plain_subs(fr["subreddits"]["value"])

    caught_by_wildcard = set()
    for sub in import_subs:
        for w in current_wildcards:
            if w in sub:
                caught_by_wildcard.add(sub)
                break

    new_subs = import_subs - current_subs - caught_by_wildcard
    if new_subs:
        print(f"New subreddits: {len(new_subs)}")
        for s in sorted(new_subs):
            print(f"  + {s}")
        current_subs.update(new_subs)
        save_lines("res-subreddits.txt", current_subs)
    else:
        print("No new subreddits")

    if caught_by_wildcard - current_subs:
        skipped = caught_by_wildcard - current_subs
        print(f"Skipped {len(skipped)} subs (already caught by wildcards)")

    # --- Sync users ---
    import_users = set(u[0] for u in fr.get("users", {}).get("value", []))
    current_users = set(u[0] for u in current_other["users"]["value"])
    new_users = import_users - current_users
    if new_users:
        print(f"\nNew users: {len(new_users)}")
        for u in sorted(new_users):
            print(f"  + {u}")
        for u in sorted(new_users):
            current_other["users"]["value"].append([u])

    # --- Sync domains ---
    import_domains = set(d[0] for d in fr.get("domains", {}).get("value", []))
    current_domains = set(d[0] for d in current_other["domains"]["value"])
    new_domains = import_domains - current_domains
    if new_domains:
        print(f"\nNew domains: {len(new_domains)}")
        for d in sorted(new_domains):
            print(f"  + {d}")
        for d in sorted(new_domains):
            current_other["domains"]["value"].append([d, "everywhere", ""])

    # --- Sync keywords ---
    import_kw = set(k[0] for k in fr.get("keywords", {}).get("value", []))
    current_kw = set(k[0] for k in current_other["keywords"]["value"])
    new_kw = import_kw - current_kw
    if new_kw:
        print(f"\nNew keywords: {len(new_kw)}")
        for k in sorted(new_kw):
            print(f"  + {k}")

    # --- Sync flair ---
    import_flair = set(f[0] for f in fr.get("flair", {}).get("value", []))
    current_flair = set(f[0] for f in current_other["flair"]["value"])
    new_flair = import_flair - current_flair
    if new_flair:
        print(f"\nNew flair filters: {len(new_flair)}")
        for fl in sorted(new_flair):
            print(f"  + {fl}")
        for fl in sorted(new_flair):
            current_other["flair"]["value"].append([fl, "everywhere", ""])

    if new_users or new_domains or new_flair:
        other_path.write_text(json.dumps(current_other, indent=2))
        print("\nUpdated res-other.json")

    total_new = len(new_subs) + len(new_users) + len(new_domains) + len(new_kw) + len(new_flair)
    if total_new:
        print(f"\nTotal new entries: {total_new}")
        print("Run 'res-build.py' to generate updated .resbackup")
    else:
        print("\nEverything is in sync — no changes needed")

    IMPORT_FILE.unlink()
    print(f"Removed {IMPORT_FILE.name}")

if __name__ == "__main__":
    main()
