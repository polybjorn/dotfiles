#!/usr/bin/env python3
"""
Music Library Cleanup Script
=============================
Filesystem-level cleanup for the music folder.

1. Fix multi-artist folder names (semicolons → first artist from tags)
2. Extract embedded cover art for albums missing cover files
3. Resize oversized cover art (>1 MB → 800x800 max)
4. Remove junk files (.DS_Store, Thumbs.db, etc.)
5. Remove empty directories

Usage:
  python3 music_cleanup.py                # Dry-run (preview changes)
  python3 music_cleanup.py --execute      # Actually clean up
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

MUSIC_DIR = Path("/mnt/tank/media/music")
LOG_DIR = MUSIC_DIR.parent / ".cleanup"
STATS_FILE = LOG_DIR / "music_stats.json"

AUDIO_SUFFIXES = {".mp3", ".flac", ".m4a", ".ogg", ".opus", ".wma", ".wav"}
IMAGE_SUFFIXES = {".jpg", ".jpeg", ".png"}
COVER_NAMES = {"cover", "folder", "front"}

JUNK_FILENAMES = {".ds_store", "thumbs.db", "desktop.ini", ".bridgesort", ".picasa.ini"}
JUNK_PREFIXES = ("._",)

MAX_COVER_BYTES = 1_000_000  # 1 MB
COVER_RESIZE_PX = 800

# Regex to split album_artist tags into primary + rest
_ARTIST_SPLIT_RE = re.compile(r"\s+(?:&|feat\.|ft\.|with)\s+|,\s+")


# ── Helpers ───────────────────────────────────────────────────────────────────

def format_size(size_bytes):
    for unit in ["B", "KB", "MB", "GB"]:
        if abs(size_bytes) < 1024:
            return f"{size_bytes:.1f} {unit}"
        size_bytes /= 1024
    return f"{size_bytes:.1f} TB"


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


def _first_audio(directory):
    """Return the first audio file found in a directory, or None."""
    for f in sorted(directory.iterdir()):
        if f.is_file() and f.suffix.lower() in AUDIO_SUFFIXES:
            return f
    return None


def _get_album_artist_tag(audio_path):
    """Read album_artist tag from an audio file via ffprobe."""
    try:
        result = subprocess.run(
            ["ffprobe", "-v", "quiet", "-show_entries",
             "format_tags=album_artist", "-of", "csv=p=0", str(audio_path)],
            capture_output=True, text=True, timeout=10,
        )
        return result.stdout.strip().strip('"')
    except (subprocess.TimeoutExpired, OSError):
        return ""


def _has_embedded_art(audio_path):
    """Check if an audio file has an embedded image stream."""
    try:
        result = subprocess.run(
            ["ffprobe", "-v", "quiet", "-show_entries",
             "stream=codec_type", "-of", "csv=p=0", str(audio_path)],
            capture_output=True, text=True, timeout=10,
        )
        return "video" in result.stdout
    except (subprocess.TimeoutExpired, OSError):
        return False


def _has_cover(album_dir):
    """Check if an album directory already has a cover image file."""
    for f in album_dir.iterdir():
        if f.is_file() and f.stem.lower() in COVER_NAMES and f.suffix.lower() in IMAGE_SUFFIXES:
            return True
    return False


# ── Phase 1: Multi-Artist Folder Renames ─────────────────────────────────────

def find_semicolon_folders():
    """Find artist folders with semicolons and map to primary artist."""
    renames = []
    for entry in sorted(MUSIC_DIR.iterdir()):
        if not entry.is_dir() or ";" not in entry.name:
            continue
        # Get primary artist from tag
        primary = None
        for album in sorted(entry.iterdir()):
            if not album.is_dir() or album.name.startswith("."):
                continue
            audio = _first_audio(album)
            if audio:
                tag = _get_album_artist_tag(audio)
                if tag:
                    primary = _ARTIST_SPLIT_RE.split(tag, maxsplit=1)[0]
                break
        if not primary:
            continue
        target = MUSIC_DIR / primary
        merge = target.exists() and target != entry
        renames.append((entry, primary, merge))
    return renames


# ── Phase 2: Missing Cover Art Extraction ────────────────────────────────────

def find_missing_covers():
    """Find album folders missing cover art that have embedded art available."""
    extractable = []
    for artist in sorted(MUSIC_DIR.iterdir()):
        if not artist.is_dir() or artist.name.startswith("."):
            continue
        for album in sorted(artist.iterdir()):
            if not album.is_dir() or album.name.startswith("."):
                continue
            if _has_cover(album):
                continue
            audio = _first_audio(album)
            if audio and _has_embedded_art(audio):
                extractable.append((album, audio))
    return extractable


# ── Phase 3: Oversized Cover Art ─────────────────────────────────────────────

def find_oversized_covers():
    """Find cover art images larger than MAX_COVER_BYTES."""
    oversized = []
    for artist in sorted(MUSIC_DIR.iterdir()):
        if not artist.is_dir() or artist.name.startswith("."):
            continue
        for album in sorted(artist.iterdir()):
            if not album.is_dir() or album.name.startswith("."):
                continue
            for f in album.iterdir():
                if (f.is_file()
                        and f.suffix.lower() in IMAGE_SUFFIXES
                        and f.stem.lower() in COVER_NAMES
                        and f.stat().st_size > MAX_COVER_BYTES):
                    oversized.append(f)
    return oversized


# ── Phase 4: Junk Files ─────────────────────────────────────────────────────

def find_junk_files():
    """Find junk/system files throughout the music directory."""
    junk = []
    for root, _dirs, files in os.walk(MUSIC_DIR):
        for name in files:
            if name.lower() in JUNK_FILENAMES or any(name.startswith(p) for p in JUNK_PREFIXES):
                junk.append(Path(root) / name)
    return junk


# ── Phase 5: Empty Directories ──────────────────────────────────────────────

def find_empty_dirs():
    """Find empty directories (bottom-up)."""
    empty = []
    for root, dirs, files in os.walk(MUSIC_DIR, topdown=False):
        path = Path(root)
        if path == MUSIC_DIR:
            continue
        if not any(path.iterdir()):
            empty.append(path)
    return empty


# ── Stats ────────────────────────────────────────────────────────────────────

def load_stats():
    if not STATS_FILE.exists():
        return {"runs": 0, "artist_renames": 0, "covers_extracted": 0,
                "covers_resized": 0, "junk_deleted": 0, "empty_dirs_removed": 0,
                "bytes_freed": 0}
    with open(STATS_FILE) as f:
        return json.load(f)


def save_stats(stats):
    os.makedirs(LOG_DIR, exist_ok=True)
    with open(STATS_FILE, "w") as f:
        json.dump(stats, f, indent=2)


# ── Main ─────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="Music library cleanup")
    parser.add_argument("--execute", action="store_true",
                        help="Actually clean up (default: dry-run)")
    args = parser.parse_args()

    dry_run = not args.execute
    mode = "DRY RUN" if dry_run else "EXECUTE"

    os.makedirs(LOG_DIR, exist_ok=True)
    log_path = LOG_DIR / ("music_dryrun.log" if dry_run else "music.log")
    log_fh = open(log_path, "a")

    def log(msg, level="INFO"):
        ts = datetime.now().strftime("%H:%M:%S")
        line = f"[{ts}] {msg}"
        print(line, flush=True)
        log_fh.write(f"[{datetime.now().isoformat()}] [{level}] {msg}\n")
        log_fh.flush()

    start_time = time.time()
    stats = {
        "artist_renames": 0, "covers_extracted": 0,
        "covers_resized": 0, "covers_bytes_saved": 0,
        "junk_deleted": 0, "junk_bytes": 0,
        "empty_dirs": 0,
    }

    log(f"{'=' * 60}")
    log(f"Music Cleanup — {mode}")
    log(f"Library: {MUSIC_DIR}")
    log(f"{'=' * 60}")

    # ── Phase 1: Multi-artist folder renames ─────────────────────────
    log("")
    log(f"{'─' * 40}")
    log("Phase 1: Multi-Artist Folder Renames")
    log(f"{'─' * 40}")

    renames = find_semicolon_folders()

    if not renames:
        log("  No semicolon artist folders found.")
    else:
        for old_path, new_name, merge in renames:
            target = MUSIC_DIR / new_name
            label = f"MERGE → {new_name}" if merge else f"RENAME → {new_name}"
            if dry_run:
                log(f"  [WOULD {label}] {old_path.name}")
            else:
                try:
                    if merge:
                        for album in sorted(old_path.iterdir()):
                            if album.is_dir() and not album.name.startswith("."):
                                dest = target / album.name
                                if not dest.exists():
                                    shutil.move(str(album), str(dest))
                        try:
                            old_path.rmdir()
                        except OSError:
                            shutil.rmtree(old_path)
                    else:
                        old_path.rename(target)
                    log(f"  [{label}] {old_path.name}")
                except OSError as e:
                    log(f"  [ERROR] {old_path.name}: {e}", level="ERROR")
                    continue
            stats["artist_renames"] += 1

    # ── Phase 2: Missing cover art extraction ────────────────────────
    log("")
    log(f"{'─' * 40}")
    log("Phase 2: Missing Cover Art Extraction")
    log(f"{'─' * 40}")

    missing_covers = find_missing_covers()

    if not missing_covers:
        log("  All albums have cover art.")
    else:
        for album_dir, audio in missing_covers:
            rel = album_dir.relative_to(MUSIC_DIR)
            cover_path = album_dir / "cover.jpg"
            if dry_run:
                log(f"  [WOULD EXTRACT] {rel}")
            else:
                try:
                    subprocess.run(
                        ["ffmpeg", "-y", "-i", str(audio), "-an", "-vcodec", "mjpeg",
                         "-q:v", "2", "-vf",
                         f"scale='min({COVER_RESIZE_PX},iw)':'min({COVER_RESIZE_PX},ih)'"
                         ":force_original_aspect_ratio=decrease",
                         str(cover_path)],
                        capture_output=True, timeout=30,
                    )
                    if cover_path.exists():
                        shutil.chown(str(cover_path), user="admin", group="media")
                        cover_path.chmod(0o640)
                        log(f"  [EXTRACTED] {rel}")
                    else:
                        log(f"  [FAILED] {rel}", level="ERROR")
                        continue
                except (subprocess.TimeoutExpired, OSError) as e:
                    log(f"  [ERROR] {rel}: {e}", level="ERROR")
                    continue
            stats["covers_extracted"] += 1

    # ── Phase 3: Oversized cover art ─────────────────────────────────
    log("")
    log(f"{'─' * 40}")
    log("Phase 3: Oversized Cover Art Resize")
    log(f"{'─' * 40}")

    oversized = find_oversized_covers()

    if not oversized:
        log("  No oversized covers found.")
    else:
        for img in oversized:
            rel = img.relative_to(MUSIC_DIR)
            old_size = img.stat().st_size
            if dry_run:
                log(f"  [WOULD RESIZE] {rel} ({format_size(old_size)})")
            else:
                try:
                    subprocess.run(
                        ["magick", str(img), "-resize",
                         f"{COVER_RESIZE_PX}x{COVER_RESIZE_PX}>",
                         "-quality", "85", str(img)],
                        capture_output=True, timeout=30,
                    )
                    new_size = img.stat().st_size
                    saved = old_size - new_size
                    log(f"  [RESIZED] {rel} ({format_size(old_size)} → {format_size(new_size)})")
                    stats["covers_bytes_saved"] += saved
                except (subprocess.TimeoutExpired, OSError) as e:
                    log(f"  [ERROR] {rel}: {e}", level="ERROR")
                    continue
            stats["covers_resized"] += 1

    # ── Phase 4: Junk files ──────────────────────────────────────────
    log("")
    log(f"{'─' * 40}")
    log("Phase 4: Junk File Removal")
    log(f"{'─' * 40}")

    junk = find_junk_files()

    if not junk:
        log("  No junk files found.")
    else:
        for path in sorted(junk):
            rel = path.relative_to(MUSIC_DIR)
            size = path.stat().st_size
            if dry_run:
                log(f"  [WOULD DEL] {rel} ({format_size(size)})")
            else:
                path.unlink()
                log(f"  [DEL] {rel} ({format_size(size)})")
            stats["junk_deleted"] += 1
            stats["junk_bytes"] += size

    # ── Phase 5: Empty directories ───────────────────────────────────
    log("")
    log(f"{'─' * 40}")
    log("Phase 5: Empty Directory Removal")
    log(f"{'─' * 40}")

    empty = find_empty_dirs()

    if not empty:
        log("  No empty directories found.")
    else:
        for path in sorted(empty):
            rel = path.relative_to(MUSIC_DIR)
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

    # ── Summary ──────────────────────────────────────────────────────
    elapsed = time.time() - start_time
    verb = "Would" if dry_run else "Done:"

    log("")
    log(f"{'=' * 60}")
    log(f"SUMMARY ({mode})")
    log(f"{'=' * 60}")
    log(f"  Artist renames:      {stats['artist_renames']}")
    log(f"  Covers extracted:    {stats['covers_extracted']}")
    log(f"  Covers resized:      {stats['covers_resized']} ({format_size(stats['covers_bytes_saved'])} saved)")
    log(f"  Junk files:          {stats['junk_deleted']} ({format_size(stats['junk_bytes'])})")
    log(f"  Empty dirs:          {stats['empty_dirs']}")
    log(f"  Time:                {elapsed:.1f}s")

    # ── Update cumulative stats ──────────────────────────────────────
    if not dry_run:
        cumulative = load_stats()
        cumulative["runs"] += 1
        cumulative["artist_renames"] += stats["artist_renames"]
        cumulative["covers_extracted"] += stats["covers_extracted"]
        cumulative["covers_resized"] += stats["covers_resized"]
        cumulative["junk_deleted"] += stats["junk_deleted"]
        cumulative["empty_dirs_removed"] += stats["empty_dirs"]
        cumulative["bytes_freed"] += stats["covers_bytes_saved"] + stats["junk_bytes"]
        cumulative["last_run"] = datetime.now().isoformat()
        save_stats(cumulative)

        has_work = any(v > 0 for k, v in stats.items() if k != "covers_bytes_saved")
        if has_work:
            parts = []
            if stats["artist_renames"]:
                parts.append(f"{stats['artist_renames']} folder(s) renamed")
            if stats["covers_extracted"]:
                parts.append(f"{stats['covers_extracted']} cover(s) extracted")
            if stats["covers_resized"]:
                parts.append(f"{stats['covers_resized']} cover(s) resized")
            if stats["junk_deleted"]:
                parts.append(f"{stats['junk_deleted']} junk file(s)")
            if stats["empty_dirs"]:
                parts.append(f"{stats['empty_dirs']} empty dir(s)")
            notify("Music Cleanup", " · ".join(parts))
        else:
            notify("Music Cleanup", "Nothing to clean — library is tidy")

        log(f"  --- All time ({cumulative['runs']} run{'s' if cumulative['runs'] != 1 else ''}) ---")
        log(f"  Total freed:         {format_size(cumulative['bytes_freed'])}")

    log(f"{'=' * 60}")
    log_fh.close()


if __name__ == "__main__":
    main()
