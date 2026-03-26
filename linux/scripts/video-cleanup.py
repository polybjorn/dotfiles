#!/usr/bin/env python3
"""
Video Library Cleanup Script
=============================
1. Strip unwanted subtitle tracks (keep: eng, nor, nob)
2. Strip unwanted audio tracks (keep: eng, nor, nob, jpn + undefined)
3. Strip font attachments (conservative: keep fonts if remaining subs use ASS/SSA)
4. Remove embedded cover art (mjpeg thumbnail streams)
5. Remux AVI/M4V/MPG/FLV/TS/WMV → MKV (lossless copy)
6. Remove redundant external .srt files (when embedded sub in same language exists)

Usage:
  python3 video_cleanup.py                    # Dry-run (preview changes)
  python3 video_cleanup.py --execute          # Actually process files
  python3 video_cleanup.py --execute --resume # Resume interrupted run
  python3 video_cleanup.py --limit 10         # Dry-run on first 10 actionable files
"""

import subprocess
import json
import os
import re
import sys
import argparse
import time
from pathlib import Path
from datetime import datetime


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

# ── Configuration ──────────────────────────────────────────────────────────────

KEEP_SUB_LANGS = {"eng", "nor", "nob"}
KEEP_AUDIO_LANGS = {"eng", "nor", "nob", "jpn"}
MEDIA_DIRS = ["/mnt/tank/media/movies", "/mnt/tank/media/series"]
REMUX_EXTENSIONS = {".avi", ".m4v", ".mpg", ".flv", ".ts", ".wmv"}
ALL_VIDEO_EXTENSIONS = {".mkv", ".mp4", ".avi", ".m4v", ".mpg", ".flv", ".ts", ".wmv"}
SRT_EXTENSIONS = {".srt"}

LOG_DIR = "/mnt/tank/media/.cleanup"
LOG_FILE = os.path.join(LOG_DIR, "cleanup.log")
PROCESSED_FILE = os.path.join(LOG_DIR, "processed.txt")

# Safety: if new file is less than this fraction of original, abort (protects against corruption)
MIN_SIZE_RATIO = 0.50

# Map common filename language tags to ISO 639-2/B codes (used by ffprobe)
LANG_ALIAS = {
    "en": "eng", "english": "eng",
    "no": "nor", "norwegian": "nor", "nb": "nob", "bokmal": "nob", "bokmål": "nob",
    "nn": "nno", "nynorsk": "nno",
    "ja": "jpn", "japanese": "jpn",
    "fr": "fre", "french": "fre",
    "de": "ger", "german": "ger",
    "es": "spa", "spanish": "spa",
    "it": "ita", "italian": "ita",
    "pt": "por", "portuguese": "por",
    "nl": "dut", "dutch": "dut",
    "sv": "swe", "swedish": "swe",
    "da": "dan", "danish": "dan",
    "fi": "fin", "finnish": "fin",
    "ko": "kor", "korean": "kor",
    "zh": "chi", "chinese": "chi",
    "ru": "rus", "russian": "rus",
    "pl": "pol", "polish": "pol",
    "ar": "ara", "arabic": "ara",
}


# ── Helpers ────────────────────────────────────────────────────────────────────

def format_size(size_bytes):
    for unit in ["B", "KB", "MB", "GB"]:
        if abs(size_bytes) < 1024:
            return f"{size_bytes:.1f} {unit}"
        size_bytes /= 1024
    return f"{size_bytes:.1f} TB"


def probe(filepath):
    """Get stream info via ffprobe. Returns dict or None on failure."""
    cmd = [
        "ffprobe", "-v", "quiet", "-print_format", "json",
        "-show_streams", str(filepath),
    ]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
        if result.returncode != 0:
            return None
        return json.loads(result.stdout)
    except (subprocess.TimeoutExpired, json.JSONDecodeError):
        return None


# ── Analysis ───────────────────────────────────────────────────────────────────

def analyze(filepath, info):
    """Determine what work a file needs. Returns analysis dict."""
    streams = info.get("streams", [])
    ext = filepath.suffix.lower()

    video = [s for s in streams if s.get("codec_type") == "video"]
    audio = [s for s in streams if s.get("codec_type") == "audio"]
    subs = [s for s in streams if s.get("codec_type") == "subtitle"]
    attachments = [s for s in streams if s.get("codec_type") == "attachment"]

    # ── Separate real video from embedded cover art (mjpeg thumbnails) ─────
    real_video = []
    cover_art = []
    for s in video:
        if s.get("codec_name") == "mjpeg":
            cover_art.append(s)
        else:
            real_video.append(s)

    # ── Classify audio tracks ─────────────────────────────────────────────
    keep_audio = []
    strip_audio = []

    for s in audio:
        lang = s.get("tags", {}).get("language", "")
        if lang in KEEP_AUDIO_LANGS:
            keep_audio.append(s)
        elif lang in ("", "und", "undetermined"):
            # Keep undefined-language audio (often the only track, or unlabeled English)
            keep_audio.append(s)
        else:
            strip_audio.append(s)

    # Safety: never strip ALL audio — if nothing would remain, keep everything
    if not keep_audio:
        keep_audio = audio
        strip_audio = []

    # ── Classify subtitles ────────────────────────────────────────────────
    keep_subs = []
    strip_subs = []
    und_subs = []

    for s in subs:
        lang = s.get("tags", {}).get("language", "")
        if lang in KEEP_SUB_LANGS:
            keep_subs.append(s)
        elif lang in ("", "und", "undetermined"):
            # Keep undefined-language subs to be safe
            und_subs.append(s)
            keep_subs.append(s)
        else:
            strip_subs.append(s)

    # Do any of the KEPT subs use ASS/SSA? (these need font attachments)
    kept_has_ass = any(
        s.get("codec_name") in ("ass", "ssa") for s in keep_subs
    )

    # Only strip attachments if no kept subs need them
    can_strip_attachments = len(attachments) > 0 and not kept_has_ass

    needs_remux = ext in REMUX_EXTENSIONS
    # Only count cover art removal if there's already another reason to remux.
    # Remuxing just for cover art causes net-negative savings (muxer overhead > tiny image).
    has_other_work = (
        len(strip_subs) > 0
        or len(strip_audio) > 0
        or can_strip_attachments
        or needs_remux
    )
    # If cover art is the ONLY reason, don't bother
    strip_cover = len(cover_art) > 0 and has_other_work
    needs_stream_work = has_other_work or strip_cover

    return {
        "video": real_video,
        "cover_art": cover_art if strip_cover else [],
        "audio": audio,
        "keep_audio": keep_audio,
        "strip_audio": strip_audio,
        "keep_subs": keep_subs,
        "strip_subs": strip_subs,
        "und_subs": und_subs,
        "attachments": attachments,
        "kept_has_ass": kept_has_ass,
        "strip_attachments": can_strip_attachments,
        "needs_remux": needs_remux,
        "needs_stream_work": needs_stream_work,
        "needs_work": needs_remux or needs_stream_work,
    }


# ── Processing ─────────────────────────────────────────────────────────────────

def build_ffmpeg_cmd(filepath, analysis, output_path):
    """Build ffmpeg command with selective stream mapping."""
    cmd = ["ffmpeg", "-y"]

    # Fix broken timestamps in old AVI/MPG files
    if filepath.suffix.lower() in REMUX_EXTENSIONS:
        cmd.extend(["-fflags", "+genpts"])

    cmd.extend(["-i", str(filepath)])

    # Map real video streams only (skip mjpeg cover art)
    for s in analysis["video"]:
        cmd.extend(["-map", f"0:{s['index']}"])

    # Map only kept audio streams
    for s in analysis["keep_audio"]:
        cmd.extend(["-map", f"0:{s['index']}"])

    # Map only kept subtitle streams
    for s in analysis["keep_subs"]:
        cmd.extend(["-map", f"0:{s['index']}"])

    # Keep attachments only if remaining subs are ASS/SSA
    if analysis["kept_has_ass"]:
        for s in analysis["attachments"]:
            cmd.extend(["-map", f"0:{s['index']}"])

    # Copy everything — no re-encoding
    cmd.extend(["-c", "copy"])
    cmd.append(str(output_path))
    return cmd


def describe_actions(analysis):
    """Human-readable description of what will happen."""
    parts = []
    if analysis["strip_audio"]:
        langs = sorted(set(
            s.get("tags", {}).get("language", "?") for s in analysis["strip_audio"]
        ))
        parts.append(f"strip {len(analysis['strip_audio'])} audio [{','.join(langs)}]")
    if analysis["strip_subs"]:
        langs = sorted(set(
            s.get("tags", {}).get("language", "?") for s in analysis["strip_subs"]
        ))
        parts.append(f"strip {len(analysis['strip_subs'])} sub(s) [{','.join(langs)}]")
    if analysis["strip_attachments"]:
        parts.append(f"strip {len(analysis['attachments'])} attachment(s)")
    if analysis["cover_art"]:
        parts.append(f"strip {len(analysis['cover_art'])} cover art")
    if analysis["needs_remux"]:
        parts.append(f"remux {analysis['video'][0].get('codec_name', '?')} → MKV")
    return " + ".join(parts)


def process_file(filepath, dry_run=True):
    """Process a single file. Returns result dict."""
    filepath = Path(filepath)
    ext = filepath.suffix.lower()

    info = probe(filepath)
    if info is None:
        return {"status": "error", "message": "ffprobe failed"}

    a = analyze(filepath, info)
    if not a["needs_work"]:
        return {"status": "skip"}

    desc = describe_actions(a)
    orig_size = filepath.stat().st_size
    und_note = f" [keeping {len(a['und_subs'])} undefined-lang sub(s)]" if a["und_subs"] else ""

    if dry_run:
        return {
            "status": "would_process",
            "message": f"{desc}{und_note}",
            "orig_size": orig_size,
        }

    # ── Determine output path ──────────────────────────────────────────────
    if a["needs_remux"]:
        # AVI/M4V/MPG → new .mkv file
        output_path = filepath.with_suffix(".mkv")
        if output_path.exists():
            return {"status": "error", "message": f"target already exists: {output_path.name}"}
    else:
        # MKV/MP4 → temp file, same extension
        output_path = filepath.with_name(filepath.stem + ".cleanup_tmp" + ext)

    # ── Run ffmpeg ─────────────────────────────────────────────────────────
    cmd = build_ffmpeg_cmd(filepath, a, output_path)
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=1800)
    except subprocess.TimeoutExpired:
        if output_path.exists():
            output_path.unlink()
        return {"status": "error", "message": "ffmpeg timed out (30 min)"}

    if result.returncode != 0:
        if output_path.exists():
            output_path.unlink()
        stderr = result.stderr.replace("\n", " ")[:300]
        return {"status": "error", "message": f"ffmpeg failed: {stderr}"}

    # ── Sanity check ───────────────────────────────────────────────────────
    # Estimate expected ratio from stream counts: video is always kept,
    # so the ratio is driven by how much audio/subs we're stripping.
    total_audio = len(a["audio"])
    kept_audio = len(a["keep_audio"])
    # Audio dominates file size; estimate audio as ~fraction of non-video.
    # If we're stripping most audio tracks, allow a proportionally smaller output.
    if total_audio > 0:
        audio_keep_ratio = kept_audio / total_audio
    else:
        audio_keep_ratio = 1.0
    # Floor: expect at least the video track (never below 0.20)
    expected_min = max(0.20, audio_keep_ratio * MIN_SIZE_RATIO)
    new_size = output_path.stat().st_size
    if new_size < orig_size * expected_min:
        output_path.unlink()
        return {
            "status": "error",
            "message": (
                f"output too small: {format_size(new_size)} vs "
                f"{format_size(orig_size)} (floor {expected_min:.0%}) — aborted for safety"
            ),
        }

    # ── Finalize ───────────────────────────────────────────────────────────
    if a["needs_remux"]:
        filepath.unlink()  # delete original .avi/.m4v/.mpg
    else:
        os.replace(str(output_path), str(filepath))  # atomic replace

    saved = orig_size - new_size
    return {
        "status": "processed",
        "message": desc,
        "orig_size": orig_size,
        "new_size": new_size,
        "saved": saved,
    }


# ── External .srt cleanup ──────────────────────────────────────────────────────

def parse_srt_language(srt_path):
    """
    Extract language from .srt filename.
    e.g. 'Movie (2024).eng.srt' → 'eng'
         'Movie (2024).en.srt'  → 'eng'  (via LANG_ALIAS)
         'Movie (2024).srt'     → None   (unknown, leave alone)
    """
    stem = srt_path.stem  # e.g. "Movie (2024).eng"
    parts = stem.rsplit(".", 1)
    if len(parts) < 2:
        return None  # no language tag in filename

    tag = parts[1].lower()
    # Already a 3-letter ISO code?
    if len(tag) == 3 and tag.isalpha():
        return tag
    # Check alias map
    return LANG_ALIAS.get(tag)


def find_video_for_srt(srt_path):
    """Find the video file that this .srt belongs to."""
    parent = srt_path.parent
    # Strip the language suffix to get the base name
    # "Movie (2024).eng.srt" → base "Movie (2024)"
    stem = srt_path.stem
    parts = stem.rsplit(".", 1)
    if len(parts) == 2 and (len(parts[1]) <= 3 or parts[1].lower() in LANG_ALIAS):
        base = parts[0]
    else:
        base = stem

    for ext in ALL_VIDEO_EXTENSIONS:
        candidate = parent / f"{base}{ext}"
        if candidate.exists():
            return candidate
    return None


def get_embedded_sub_langs(video_path):
    """Return set of language codes for embedded subtitle tracks."""
    info = probe(video_path)
    if not info:
        return set()
    langs = set()
    for s in info.get("streams", []):
        if s.get("codec_type") == "subtitle":
            lang = s.get("tags", {}).get("language", "")
            if lang:
                langs.add(lang)
    return langs


def analyze_srt(srt_path):
    """
    Determine if an external .srt should be deleted.
    Returns: (should_delete: bool, reason: str)
    """
    lang = parse_srt_language(srt_path)

    # Can't determine language → keep to be safe
    if lang is None:
        return False, "unknown language, keeping"

    # Language not in our keep list → user doesn't want it
    if lang not in KEEP_SUB_LANGS:
        return True, f"unwanted language: {lang}"

    # Language IS in keep list — check if video already has it embedded
    video = find_video_for_srt(srt_path)
    if video is None:
        return False, "no matching video file found"

    embedded = get_embedded_sub_langs(video)
    if lang in embedded:
        return True, f"redundant (embedded {lang} exists in {video.name})"

    # Kept language, not embedded → this .srt is the only copy, keep it
    return False, f"only copy of {lang} subs"


def find_srt_files(dirs):
    """Recursively find all .srt files."""
    files = []
    for d in dirs:
        p = Path(d)
        if not p.exists():
            continue
        files.extend(p.rglob("*.srt"))
    return sorted(files)


# ── Main ───────────────────────────────────────────────────────────────────────

def find_media_files(dirs):
    """Recursively find all video files."""
    files = []
    for d in dirs:
        p = Path(d)
        if not p.exists():
            continue
        for ext in ALL_VIDEO_EXTENSIONS:
            files.extend(p.rglob(f"*{ext}"))
    return sorted(files)


STATS_FILE = os.path.join(LOG_DIR, "cumulative_stats.json")


def load_processed(path):
    if not os.path.exists(path):
        return set()
    with open(path, "r") as f:
        return set(line.strip() for line in f if line.strip())


def load_cumulative_stats():
    if not os.path.exists(STATS_FILE):
        return {"total_bytes_saved": 0, "total_files_processed": 0, "total_srts_deleted": 0, "runs": 0}
    with open(STATS_FILE, "r") as f:
        return json.load(f)


def save_cumulative_stats(cumulative):
    with open(STATS_FILE, "w") as f:
        json.dump(cumulative, f, indent=2)


def main():
    parser = argparse.ArgumentParser(description="Media library cleanup")
    parser.add_argument("--execute", action="store_true",
                        help="Actually process files (default: dry-run)")
    parser.add_argument("--resume", action="store_true",
                        help="Skip already-processed files")
    parser.add_argument("--limit", type=int, default=0,
                        help="Stop after N actionable files (0 = unlimited)")
    args = parser.parse_args()

    dry_run = not args.execute

    # Setup log directory
    os.makedirs(LOG_DIR, exist_ok=True)

    log_path = os.path.join(LOG_DIR, "dryrun.log" if dry_run else "cleanup.log")
    log_fh = open(log_path, "a")

    def log(msg, level="INFO"):
        ts = datetime.now().strftime("%H:%M:%S")
        line = f"[{ts}] {msg}"
        print(line, flush=True)
        log_fh.write(f"[{datetime.now().isoformat()}] [{level}] {msg}\n")
        log_fh.flush()

    mode = "DRY RUN" if dry_run else "EXECUTE"
    log(f"{'=' * 60}")
    log(f"Video Cleanup — {mode}")
    log(f"Keep subs:  {', '.join(sorted(KEEP_SUB_LANGS))}")
    log(f"Keep audio: {', '.join(sorted(KEEP_AUDIO_LANGS))}")
    log(f"{'=' * 60}")

    # Find files
    log("Scanning for media files...")
    files = find_media_files(MEDIA_DIRS)
    log(f"Found {len(files)} media files")

    # Resume support
    processed = load_processed(PROCESSED_FILE) if args.resume else set()
    if processed:
        log(f"Resuming: skipping {len(processed)} already-processed files")

    # Stats
    stats = {
        "scanned": 0, "would_process": 0, "processed": 0,
        "clean": 0, "errors": 0, "bytes_saved": 0, "actionable_hit": 0,
    }
    start_time = time.time()

    processed_fh = open(PROCESSED_FILE, "a") if not dry_run else None

    try:
        for filepath in files:
            fstr = str(filepath)
            if fstr in processed:
                continue

            stats["scanned"] += 1

            result = process_file(filepath, dry_run=dry_run)
            status = result["status"]

            if status == "skip":
                stats["clean"] += 1

            elif status == "would_process":
                stats["would_process"] += 1
                stats["actionable_hit"] += 1
                log(f"  [WOULD] {filepath.name}")
                log(f"          {result['message']}")
                if args.limit and stats["actionable_hit"] >= args.limit:
                    log(f"Reached --limit {args.limit}, stopping.")
                    break

            elif status == "processed":
                stats["processed"] += 1
                stats["actionable_hit"] += 1
                stats["bytes_saved"] += result.get("saved", 0)
                log(f"  [DONE] {filepath.name}")
                log(f"         {result['message']} — saved {format_size(result['saved'])}")
                if processed_fh:
                    processed_fh.write(fstr + "\n")
                    processed_fh.flush()
                if args.limit and stats["actionable_hit"] >= args.limit:
                    log(f"Reached --limit {args.limit}, stopping.")
                    break

            elif status == "error":
                stats["errors"] += 1
                log(f"  [ERROR] {filepath.name}: {result['message']}", level="ERROR")

            # Progress every 500 files
            if stats["scanned"] % 500 == 0:
                elapsed = time.time() - start_time
                rate = stats["scanned"] / elapsed if elapsed > 0 else 0
                log(f"  ... {stats['scanned']}/{len(files)} scanned ({rate:.0f} files/sec)")

    except KeyboardInterrupt:
        log("Interrupted by user (Ctrl+C)")

    # ── Phase 2: External .srt cleanup ───────────────────────────────────
    log("")
    log(f"{'=' * 60}")
    log(f"Phase 2: External .srt cleanup")
    log(f"{'=' * 60}")
    log("Scanning for .srt files...")
    srt_files = find_srt_files(MEDIA_DIRS)
    log(f"Found {len(srt_files)} .srt files")

    srt_stats = {"scanned": 0, "deleted": 0, "would_delete": 0, "kept": 0, "bytes_saved": 0}

    for srt_path in srt_files:
        srt_str = str(srt_path)
        if srt_str in processed:
            continue

        srt_stats["scanned"] += 1
        should_delete, reason = analyze_srt(srt_path)

        if should_delete:
            srt_size = srt_path.stat().st_size
            if dry_run:
                srt_stats["would_delete"] += 1
                log(f"  [WOULD DEL] {srt_path.name}: {reason}")
            else:
                srt_path.unlink()
                srt_stats["deleted"] += 1
                srt_stats["bytes_saved"] += srt_size
                log(f"  [DEL] {srt_path.name}: {reason}")
                if processed_fh:
                    processed_fh.write(srt_str + "\n")
                    processed_fh.flush()
        else:
            srt_stats["kept"] += 1

    if processed_fh:
        processed_fh.close()

    # ── Update cumulative stats ─────────────────────────────────────────
    cumulative = load_cumulative_stats()
    if not dry_run:
        cumulative["total_bytes_saved"] += stats["bytes_saved"] + srt_stats["bytes_saved"]
        cumulative["total_files_processed"] += stats["processed"]
        cumulative["total_srts_deleted"] += srt_stats["deleted"]
        cumulative["runs"] += 1
        cumulative["last_run"] = datetime.now().isoformat()
        save_cumulative_stats(cumulative)

    # Summary
    elapsed = time.time() - start_time
    log("")
    log(f"{'=' * 60}")
    log(f"SUMMARY ({mode})")
    log(f"{'=' * 60}")
    log(f"  --- Video files ---")
    log(f"  Files scanned:      {stats['scanned']}")
    if dry_run:
        log(f"  Would process:      {stats['would_process']}")
    else:
        log(f"  Processed:          {stats['processed']}")
        log(f"  Space saved:        {format_size(stats['bytes_saved'])}")
    log(f"  Already clean:      {stats['clean']}")
    log(f"  Errors:             {stats['errors']}")
    log(f"  --- External .srt ---")
    log(f"  .srt scanned:       {srt_stats['scanned']}")
    if dry_run:
        log(f"  Would delete:       {srt_stats['would_delete']}")
    else:
        log(f"  Deleted:            {srt_stats['deleted']}")
        log(f"  .srt space saved:   {format_size(srt_stats['bytes_saved'])}")
    log(f"  Kept:               {srt_stats['kept']}")
    log(f"  --- This run ---")
    total_this_run = stats["bytes_saved"] + srt_stats.get("bytes_saved", 0)
    log(f"  Total saved:        {format_size(total_this_run)}")
    log(f"  Time:               {elapsed:.1f}s")
    if cumulative["runs"] > 0:
        log(f"  --- All time ({cumulative['runs']} run{'s' if cumulative['runs'] != 1 else ''}) ---")
        log(f"  Total saved:        {format_size(cumulative['total_bytes_saved'])}")
        log(f"  Files processed:    {cumulative['total_files_processed']}")
        log(f"  SRTs deleted:       {cumulative['total_srts_deleted']}")
    log(f"{'=' * 60}")

    # ── Send notification ─────────────────────────────────────────────
    if not dry_run:
        total_saved = stats["bytes_saved"] + srt_stats.get("bytes_saved", 0)
        has_work = stats["processed"] > 0 or srt_stats["deleted"] > 0
        if has_work:
            parts = []
            if stats["processed"] > 0:
                parts.append(f"{stats['processed']} file(s) cleaned")
            if srt_stats["deleted"] > 0:
                parts.append(f"{srt_stats['deleted']} srt(s) removed")
            if total_saved > 0:
                parts.append(f"{format_size(total_saved)} saved")
            if stats["errors"] > 0:
                parts.append(f"{stats['errors']} error(s)")
            notify("Video Cleanup ✓", " · ".join(parts))
        else:
            notify("Video Cleanup ✓", "Nothing to process — library is clean")

    log_fh.close()


if __name__ == "__main__":
    main()
