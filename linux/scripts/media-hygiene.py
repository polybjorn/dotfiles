#!/usr/bin/env python3
"""
Media Library Hygiene Script
=============================
Filesystem-level structural cleanup across all media folders.
Companion to video_cleanup.py (which handles stream-level ffmpeg work).

1. Remove known junk files (.DS_Store, Thumbs.db, stale app data)
2. Detect and remove podcast duplicate episodes (UUID-suffixed copies)
3. Remove empty directories (bottom-up)
4. Report naming inconsistencies (log-only, never auto-renames)

Usage:
  python3 -B media_hygiene.py                # Dry-run (preview changes)
  python3 -B media_hygiene.py --execute      # Actually clean up
"""

import os
import re
import sys
import json
import shutil
import subprocess
import argparse
import time
from pathlib import Path
from datetime import datetime

# ── Configuration ─────────────────────────────────────────────────────────────

MEDIA_ROOT = Path("/mnt/tank/media")

# All media subdirectories to scan
MEDIA_DIRS = [
    MEDIA_ROOT / "movies",
    MEDIA_ROOT / "series",
    MEDIA_ROOT / "music",
    MEDIA_ROOT / "podcasts",
    MEDIA_ROOT / "audiobooks",
    MEDIA_ROOT / "books",
]

# Directories to never touch
PROTECTED_DIRS = {".cleanup", ".claude"}

# Known junk filenames (case-insensitive match)
JUNK_FILENAMES = {
    ".ds_store",
    "thumbs.db",
    "desktop.ini",
    ".bridgesort",
    ".picasa.ini",
}


# Podcast UUID pattern: (xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx)
UUID_RE = re.compile(r"\s*\([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\)")

# Movie folder year pattern
MOVIE_YEAR_RE = re.compile(r"\(\d{4}\)$")

LOG_DIR = MEDIA_ROOT / ".cleanup"
STATS_FILE = LOG_DIR / "hygiene_stats.json"


# ── Helpers ───────────────────────────────────────────────────────────────────

def format_size(size_bytes):
    for unit in ["B", "KB", "MB", "GB"]:
        if abs(size_bytes) < 1024:
            return f"{size_bytes:.1f} {unit}"
        size_bytes /= 1024
    return f"{size_bytes:.1f} TB"


def is_protected(path):
    """Check if a path is inside a protected directory."""
    parts = Path(path).parts
    return any(p in PROTECTED_DIRS for p in parts)


def dir_size(path):
    """Total size of all files in a directory (non-recursive for single level)."""
    total = 0
    try:
        for entry in os.scandir(path):
            if entry.is_file(follow_symlinks=False):
                total += entry.stat().st_size
    except OSError:
        pass
    return total


def notify(title, message):
    """Send a push notification via ntfy."""
    try:
        env_file = Path.home() / ".config/dotfiles/env"
        topic = None
        if env_file.exists():
            for line in env_file.read_text().splitlines():
                if line.startswith("NTFY_TOPIC="):
                    topic = line.split("=", 1)[1].strip().strip('"\'')
        cmd = [str(Path.home() / ".local/bin/ntfy")]
        if topic:
            cmd.extend(["-t", topic])
        cmd.extend([title, message])
        subprocess.run(cmd, timeout=15, capture_output=True)
    except (FileNotFoundError, subprocess.TimeoutExpired, OSError):
        pass


# ── Phase 1: Junk File Cleanup ───────────────────────────────────────────────

def find_junk_files():
    """Find all known junk files across media directories."""
    junk = []

    # Scan all media dirs for junk filenames
    for media_dir in MEDIA_DIRS:
        if not media_dir.exists():
            continue
        for root, dirs, files in os.walk(media_dir):
            # Skip protected dirs
            dirs[:] = [d for d in dirs if d not in PROTECTED_DIRS]
            for f in files:
                if f.lower() in JUNK_FILENAMES:
                    junk.append(Path(root) / f)

    # Also check media root itself
    for f in os.listdir(MEDIA_ROOT):
        if f.lower() in JUNK_FILENAMES:
            junk.append(MEDIA_ROOT / f)

    return junk


def find_stale_app_data():
    """Find stale application artifacts (__pycache__)."""
    stale_files = []
    stale_dirs = []

    # __pycache__ anywhere under media root
    for root, dirs, _files in os.walk(MEDIA_ROOT):
        dirs[:] = [d for d in dirs if d not in PROTECTED_DIRS]
        if "__pycache__" in dirs:
            stale_dirs.append(Path(root) / "__pycache__")
            dirs.remove("__pycache__")  # Don't descend into it

    return stale_files, stale_dirs


# ── Phase 2: Podcast Duplicate Detection ──────────────────────────────────────

def find_podcast_duplicates():
    """Find podcast episodes with UUID suffixes that have a clean counterpart."""
    podcast_dir = MEDIA_ROOT / "podcasts"
    if not podcast_dir.exists():
        return [], []

    duplicates = []  # (uuid_path, clean_path) — safe to delete uuid_path
    unique_uuid = []  # uuid_path with no clean counterpart — keep but report

    for root, _dirs, files in os.walk(podcast_dir):
        root_path = Path(root)
        for f in files:
            match = UUID_RE.search(Path(f).stem)
            if not match:
                continue

            uuid_path = root_path / f
            # Build the clean filename by removing the UUID portion
            stem = Path(f).stem
            suffix = Path(f).suffix
            clean_stem = UUID_RE.sub("", stem).rstrip()
            clean_path = root_path / f"{clean_stem}{suffix}"

            if clean_path.exists():
                duplicates.append((uuid_path, clean_path))
            else:
                unique_uuid.append(uuid_path)

    return duplicates, unique_uuid


# ── Phase 3: Empty Directory Cleanup ──────────────────────────────────────────

def find_empty_dirs():
    """Find empty directories bottom-up across all media dirs."""
    empty = []

    for media_dir in MEDIA_DIRS:
        if not media_dir.exists():
            continue
        # Walk bottom-up so child dirs are processed before parents
        for root, dirs, files in os.walk(media_dir, topdown=False):
            path = Path(root)
            if is_protected(path):
                continue
            # Don't remove the media dir itself
            if path == media_dir:
                continue
            try:
                if not any(True for _ in os.scandir(path)):
                    empty.append(path)
            except OSError:
                pass

    return empty


# ── Phase 4: Inconsistency Report ────────────────────────────────────────────

def find_inconsistencies():
    """Find naming issues (report only, never fix)."""
    issues = []

    # Movie folders without proper (YYYY) year
    movies_dir = MEDIA_ROOT / "movies"
    if movies_dir.exists():
        for entry in sorted(movies_dir.iterdir()):
            if not entry.is_dir():
                continue
            if not MOVIE_YEAR_RE.search(entry.name):
                issues.append(("movie_year", entry.name, entry))

    return issues


# ── Stats ─────────────────────────────────────────────────────────────────────

def load_cumulative_stats():
    if not STATS_FILE.exists():
        return {
            "total_files_deleted": 0,
            "total_dirs_removed": 0,
            "total_bytes_freed": 0,
            "total_podcast_dupes_removed": 0,
            "runs": 0,
        }
    with open(STATS_FILE) as f:
        return json.load(f)


def save_cumulative_stats(stats):
    with open(STATS_FILE, "w") as f:
        json.dump(stats, f, indent=2)


# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="Media library hygiene cleanup")
    parser.add_argument("--execute", action="store_true",
                        help="Actually clean up (default: dry-run)")
    args = parser.parse_args()

    dry_run = not args.execute
    mode = "DRY RUN" if dry_run else "EXECUTE"

    # Setup logging
    os.makedirs(LOG_DIR, exist_ok=True)
    log_path = LOG_DIR / ("hygiene_dryrun.log" if dry_run else "hygiene.log")
    log_fh = open(log_path, "a")

    def log(msg, level="INFO"):
        ts = datetime.now().strftime("%H:%M:%S")
        line = f"[{ts}] {msg}"
        print(line, flush=True)
        log_fh.write(f"[{datetime.now().isoformat()}] [{level}] {msg}\n")
        log_fh.flush()

    start_time = time.time()
    stats = {
        "junk_files": 0, "junk_bytes": 0,
        "stale_files": 0, "stale_dirs": 0, "stale_bytes": 0,
        "podcast_dupes": 0, "podcast_dupe_bytes": 0,
        "empty_dirs": 0,
        "inconsistencies": 0,
    }

    log(f"{'=' * 60}")
    log(f"Media Hygiene — {mode}")
    log(f"Root: {MEDIA_ROOT}")
    log(f"{'=' * 60}")

    # ── Phase 1: Junk files ───────────────────────────────────────────────
    log("")
    log(f"{'─' * 40}")
    log("Phase 1: Junk File Cleanup")
    log(f"{'─' * 40}")

    junk_files = find_junk_files()
    stale_files, stale_dirs = find_stale_app_data()

    if not junk_files and not stale_files and not stale_dirs:
        log("  No junk files found.")
    else:
        for path in sorted(junk_files):
            size = path.stat().st_size
            rel = path.relative_to(MEDIA_ROOT)
            if dry_run:
                log(f"  [WOULD DEL] {rel} ({format_size(size)})")
            else:
                path.unlink()
                log(f"  [DEL] {rel} ({format_size(size)})")
            stats["junk_files"] += 1
            stats["junk_bytes"] += size

        for path in sorted(stale_files):
            size = path.stat().st_size
            rel = path.relative_to(MEDIA_ROOT)
            if dry_run:
                log(f"  [WOULD DEL] {rel} ({format_size(size)}) — stale app data")
            else:
                path.unlink()
                log(f"  [DEL] {rel} ({format_size(size)}) — stale app data")
            stats["stale_files"] += 1
            stats["stale_bytes"] += size

        for path in sorted(stale_dirs):
            size = dir_size(path)
            rel = path.relative_to(MEDIA_ROOT)
            if dry_run:
                log(f"  [WOULD RMDIR] {rel}/ ({format_size(size)}) — stale app data")
            else:
                shutil.rmtree(path)
                log(f"  [RMDIR] {rel}/ ({format_size(size)}) — stale app data")
            stats["stale_dirs"] += 1
            stats["stale_bytes"] += size

    # ── Phase 2: Podcast duplicates ───────────────────────────────────────
    log("")
    log(f"{'─' * 40}")
    log("Phase 2: Podcast Duplicate Detection")
    log(f"{'─' * 40}")

    duplicates, unique_uuid = find_podcast_duplicates()

    if not duplicates and not unique_uuid:
        log("  No podcast duplicates found.")
    else:
        for uuid_path, clean_path in duplicates:
            size = uuid_path.stat().st_size
            rel = uuid_path.relative_to(MEDIA_ROOT)
            clean_rel = clean_path.relative_to(MEDIA_ROOT)
            if dry_run:
                log(f"  [WOULD DEL] {rel}")
                log(f"              duplicate of: {clean_rel}")
            else:
                uuid_path.unlink()
                log(f"  [DEL] {rel}")
                log(f"        duplicate of: {clean_rel}")
            stats["podcast_dupes"] += 1
            stats["podcast_dupe_bytes"] += size

        for uuid_path in unique_uuid:
            rel = uuid_path.relative_to(MEDIA_ROOT)
            log(f"  [NOTICE] {rel}")
            log(f"           UUID in filename but no clean counterpart — keeping")

    # ── Phase 3: Empty directories ────────────────────────────────────────
    log("")
    log(f"{'─' * 40}")
    log("Phase 3: Empty Directory Cleanup")
    log(f"{'─' * 40}")

    empty_dirs = find_empty_dirs()

    if not empty_dirs:
        log("  No empty directories found.")
    else:
        for path in sorted(empty_dirs):
            rel = path.relative_to(MEDIA_ROOT)
            if dry_run:
                log(f"  [WOULD RMDIR] {rel}/")
            else:
                try:
                    path.rmdir()
                    log(f"  [RMDIR] {rel}/")
                except OSError as e:
                    log(f"  [ERROR] {rel}/: {e}", level="ERROR")
                    continue
            stats["empty_dirs"] += 1

    # ── Phase 4: Inconsistency report ─────────────────────────────────────
    log("")
    log(f"{'─' * 40}")
    log("Phase 4: Inconsistency Report")
    log(f"{'─' * 40}")

    issues = find_inconsistencies()

    if not issues:
        log("  No inconsistencies found.")
    else:
        for kind, name, path in issues:
            if kind == "movie_year":
                log(f"  [WARN] Movie folder missing year: {name}", level="WARN")
            stats["inconsistencies"] += 1

    # ── Update cumulative stats ───────────────────────────────────────────
    cumulative = load_cumulative_stats()
    total_bytes = stats["junk_bytes"] + stats["stale_bytes"] + stats["podcast_dupe_bytes"]
    total_files = stats["junk_files"] + stats["stale_files"] + stats["podcast_dupes"]
    total_dirs = stats["stale_dirs"] + stats["empty_dirs"]

    if not dry_run:
        cumulative["total_files_deleted"] += total_files
        cumulative["total_dirs_removed"] += total_dirs
        cumulative["total_bytes_freed"] += total_bytes
        cumulative["total_podcast_dupes_removed"] += stats["podcast_dupes"]
        cumulative["runs"] += 1
        cumulative["last_run"] = datetime.now().isoformat()
        save_cumulative_stats(cumulative)

    # ── Summary ───────────────────────────────────────────────────────────
    elapsed = time.time() - start_time
    log("")
    log(f"{'=' * 60}")
    log(f"SUMMARY ({mode})")
    log(f"{'=' * 60}")
    verb = "Would delete" if dry_run else "Deleted"
    verb_dir = "Would remove" if dry_run else "Removed"
    log(f"  --- Junk files ---")
    log(f"  {verb}:            {stats['junk_files']} file(s) ({format_size(stats['junk_bytes'])})")
    log(f"  --- Stale app data ---")
    log(f"  {verb}:            {stats['stale_files']} file(s), {stats['stale_dirs']} dir(s) ({format_size(stats['stale_bytes'])})")
    log(f"  --- Podcast duplicates ---")
    log(f"  {verb}:            {stats['podcast_dupes']} duplicate(s) ({format_size(stats['podcast_dupe_bytes'])})")
    log(f"  --- Empty directories ---")
    log(f"  {verb_dir}:         {stats['empty_dirs']} empty dir(s)")
    log(f"  --- Inconsistencies ---")
    log(f"  Warnings:            {stats['inconsistencies']}")
    log(f"  --- This run ---")
    log(f"  Total freed:         {format_size(total_bytes)}")
    log(f"  Time:                {elapsed:.1f}s")
    if cumulative["runs"] > 0:
        log(f"  --- All time ({cumulative['runs']} run{'s' if cumulative['runs'] != 1 else ''}) ---")
        log(f"  Total freed:         {format_size(cumulative['total_bytes_freed'])}")
        log(f"  Files deleted:       {cumulative['total_files_deleted']}")
        log(f"  Dirs removed:        {cumulative['total_dirs_removed']}")
    log(f"{'=' * 60}")

    # ── Send notification ─────────────────────────────────────────────
    if not dry_run:
        has_work = total_files > 0 or total_dirs > 0
        if has_work:
            parts = []
            if total_files > 0:
                parts.append(f"{total_files} file(s) deleted")
            if total_dirs > 0:
                parts.append(f"{total_dirs} dir(s) removed")
            if total_bytes > 0:
                parts.append(f"{format_size(total_bytes)} freed")
            if stats["inconsistencies"] > 0:
                parts.append(f"{stats['inconsistencies']} warning(s)")
            notify("Media Hygiene ✓", " · ".join(parts))
        else:
            notify("Media Hygiene ✓", "Nothing to clean — library is tidy")

    log_fh.close()


if __name__ == "__main__":
    main()
