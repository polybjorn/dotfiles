#!/usr/bin/env python3
"""Build a RES .resbackup file from sorted source files.

Reads from RES_DATA_DIR (default: ~/Vault/Backups/librewolf):
  res-subreddits.txt     — one exact subreddit name per line
  res-wildcards.txt      — one wildcard/substring pattern per line (case-insensitive)
  res-wildcards-cs.txt   — case-sensitive wildcard patterns (optional)
  res-other.json         — users, keywords, domains, flair, custom filters

Writes:
  reddit-enhancement-suite.resbackup  — importable RES backup

Flags:
  --sync    Import new entries from .resbackup into source files before building
"""

import json
import os
import re
import sys
from pathlib import Path

DATA_DIR = Path(os.environ.get("RES_DATA_DIR", Path.home() / "Vault/Backups/librewolf"))
BATCH_SIZE = 1000

def load_lines(filename, required=True):
    path = DATA_DIR / filename
    if not path.exists():
        if required:
            print(f"Missing: {path}")
            sys.exit(1)
        return []
    lines = []
    for line in path.read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            lines.append(line)
    return lines

def load_set(filename):
    return {l.lower() for l in load_lines(filename, required=False)}

def save_sorted(filename, lines):
    path = DATA_DIR / filename
    seen = set()
    unique = []
    for s in sorted(lines, key=str.lower):
        if s.strip() and s.lower() not in seen:
            seen.add(s.lower())
            unique.append(s.strip())
    path.write_text("\n".join(unique) + "\n")
    return len(unique)

def sync_from_backup():
    """Parse .resbackup and import new entries into source files."""
    backup_path = DATA_DIR / "reddit-enhancement-suite.resbackup"
    if not backup_path.exists():
        print("No .resbackup found, skipping sync")
        return

    data = json.loads(backup_path.read_text())
    fr = data.get("data", {}).get("RESoptions.filteReddit", {})
    sub_entries = fr.get("subreddits", {}).get("value", [])

    bk_exact = set()
    bk_wc_ci = set()
    bk_wc_cs = set()

    for entry in sub_entries:
        pattern = entry[0]
        # Plain string (manually added in RES UI)
        if not pattern.startswith("/"):
            bk_exact.add(pattern)
            continue
        # Exact-match batch: /^(foo|bar)$/i
        m = re.match(r'^/\^\((.+)\)\$/i$', pattern)
        if m:
            bk_exact.update(m.group(1).split("|"))
            continue
        # Case-insensitive wildcard: /(foo|bar)/i
        m = re.match(r'^/\((.+)\)/i$', pattern)
        if m:
            bk_wc_ci.update(m.group(1).split("|"))
            continue
        # Case-sensitive wildcard: /(foo|bar)/
        m = re.match(r'^/\((.+)\)/$', pattern)
        if m:
            bk_wc_cs.update(m.group(1).split("|"))
            continue

    src_subs = load_set("res-subreddits.txt")
    src_wc = load_set("res-wildcards.txt")
    src_wc_cs = load_set("res-wildcards-cs.txt")

    new_subs = [s for s in bk_exact if s.lower() not in src_subs]
    new_wc = [w for w in bk_wc_ci if w.lower() not in src_wc]
    new_wc_cs = [w for w in bk_wc_cs if w.lower() not in src_wc_cs]

    # Sync other filters (users, keywords, domains, flair)
    other_path = DATA_DIR / "res-other.json"
    other_changed = False
    if other_path.exists():
        other = json.loads(other_path.read_text())
        for key in ["users", "keywords", "domains", "flair"]:
            if key not in fr or key not in other:
                continue
            src_vals = {json.dumps(v, sort_keys=True) for v in other[key]["value"]}
            bk_vals = fr[key]["value"]
            new_vals = [v for v in bk_vals if json.dumps(v, sort_keys=True) not in src_vals]
            if new_vals:
                other[key]["value"].extend(new_vals)
                other_changed = True
                print(f"  Synced {len(new_vals)} new {key}")
        if other_changed:
            other_path.write_text(json.dumps(other, indent=2) + "\n")

    if not new_subs and not new_wc and not new_wc_cs and not other_changed:
        print("Sync: source files already up to date")
        return

    if new_subs:
        all_subs = load_lines("res-subreddits.txt") + new_subs
        count = save_sorted("res-subreddits.txt", all_subs)
        print(f"  Synced {len(new_subs)} new subreddits (total: {count})")
    if new_wc:
        all_wc = load_lines("res-wildcards.txt") + new_wc
        count = save_sorted("res-wildcards.txt", all_wc)
        print(f"  Synced {len(new_wc)} new wildcards (total: {count})")
    if new_wc_cs:
        all_wc_cs = load_lines("res-wildcards-cs.txt", required=False) + new_wc_cs
        count = save_sorted("res-wildcards-cs.txt", all_wc_cs)
        print(f"  Synced {len(new_wc_cs)} new case-sensitive wildcards (total: {count})")

def build_wildcard_entry(patterns, case_sensitive=False):
    """Single regex entry for substring/wildcard matching."""
    joined = "|".join(patterns)
    flags = "" if case_sensitive else "i"
    return [f"/({joined})/{flags}"]

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

    if "--sync" in sys.argv:
        print("Syncing from .resbackup...")
        sync_from_backup()

    subreddits = load_lines("res-subreddits.txt")
    wildcards = load_lines("res-wildcards.txt")
    wildcards_cs = load_lines("res-wildcards-cs.txt", required=False)

    other_path = DATA_DIR / "res-other.json"
    if not other_path.exists():
        print(f"Missing: {other_path}")
        sys.exit(1)
    other = json.loads(other_path.read_text())

    sub_entries = []
    sub_entries.append(build_wildcard_entry(wildcards))
    if wildcards_cs:
        sub_entries.append(build_wildcard_entry(wildcards_cs, case_sensitive=True))
    sub_entries.extend(build_exact_batches(subreddits))

    filte_reddit = {
        "hideUntilProcessed": {"value": True},
        "NSFWfilter": {"value": False},
        "allowNSFW": {"value": []},
        "NSFWQuickToggle": {"value": True},
        "showFilterline": {"value": False},
        "excludeOwnPosts": {"value": True},
        "excludeModqueue": {"value": True},
        "excludeUserPages": {"value": False},
        "subreddits": {"value": sub_entries},
        "filterSubredditsFrom": {"value": "everywhere-except-subreddit"},
        "useRedditFilters": {"value": False},
        "keywords": other["keywords"],
        "users": other["users"],
        "usersMatchAction": {"value": "hide"},
        "usersMatchRepliesAction": {"value": "collapse"},
        "domains": other["domains"],
        "flair": other["flair"],
        "customFiltersP": other["customFiltersP"],
        "customFiltersC": {"value": []},
    }

    backup = {
        "SCHEMA_VERSION": 2,
        "data": {
            "RESoptions.filteReddit": filte_reddit,
        },
    }

    out_path = DATA_DIR / "reddit-enhancement-suite.resbackup"
    out_path.write_text(json.dumps(backup))

    wildcard_entries = 1 + (1 if wildcards_cs else 0)
    total_entries = len(sub_entries)
    print(f"Subreddits: {len(subreddits)} names → {total_entries - wildcard_entries} exact-match batches")
    print(f"Wildcards:  {len(wildcards)} patterns → 1 entry (case-insensitive)")
    if wildcards_cs:
        print(f"Wildcards:  {len(wildcards_cs)} patterns → 1 entry (case-sensitive)")
    print(f"Total subreddit filter entries: {total_entries}")
    print(f"Users: {len(other['users']['value'])}, Domains: {len(other['domains']['value'])}")
    print(f"Keywords: {len(other['keywords']['value'])}, Flair: {len(other['flair']['value'])}")
    print(f"Wrote: {out_path}")

if __name__ == "__main__":
    main()
