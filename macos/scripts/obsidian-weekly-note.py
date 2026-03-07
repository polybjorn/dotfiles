#!/usr/bin/env python3
"""Generate a pre-populated Obsidian weekly note every Monday.

Reads from Project planning, quarterly goals, and previous week's note
to auto-fill Projects, Next week, and carry-forward items.

Designed to run via launchd (StartCalendarInterval) on Mondays.
"""

import re
import sys
from datetime import date, timedelta
from pathlib import Path

VAULT = Path.home() / "Vault" / "Obsidian"
LOG = Path("/tmp/obsidian-weekly-note.log")


def log(msg):
  with open(LOG, "a") as f:
    f.write(f"{date.today()} {msg}\n")


def week_filename(monday):
  _, week, _ = monday.isocalendar()
  return f"{monday.year}-{monday.month:02d} W{week:02d}.md"


def week_path(monday):
  return VAULT / "Calendar" / str(monday.year) / week_filename(monday)


def extract_section(content, heading):
  pattern = rf"^## {re.escape(heading)}\s*\n(.*?)(?=^## |\Z)"
  match = re.search(pattern, content, re.MULTILINE | re.DOTALL)
  return match.group(1).strip() if match else ""


def get_active_projects():
  planning = VAULT / "Project planning.md"
  if not planning.exists():
    return []
  content = planning.read_text()
  projects = []
  in_table = False
  for line in content.split("\n"):
    if "| Project" in line and "Priority" in line:
      in_table = True
      continue
    if in_table and line.startswith("|"):
      if "---" in line:
        continue
      cols = [c.strip() for c in line.split("|")[1:-1]]
      if len(cols) >= 4 and cols[0]:
        note = f" — {cols[3]}" if cols[3] else ""
        projects.append(f"- {cols[0]}{note}")
      else:
        in_table = False
    elif in_table:
      in_table = False
  return projects


def get_quarterly_goals(year, month):
  quarter_names = {1: "First", 2: "Second", 3: "Third", 4: "Fourth"}
  q = (month - 1) // 3 + 1
  for qi in [q, q - 1 if q > 1 else 4]:
    qname = quarter_names[qi]
    qfile = VAULT / "Calendar" / str(year) / f"{year} {qname} quarter review.md"
    if qfile.exists():
      content = qfile.read_text()
      goals = extract_section(content, "Goals")
      unchecked = [
        line.strip() for line in goals.split("\n") if line.strip().startswith("- [ ]")
      ]
      if unchecked:
        return unchecked
  return []


def get_prev_next_week(prev_path):
  if prev_path is None or not prev_path.exists():
    return []
  content = prev_path.read_text()
  section = extract_section(content, "Next week")
  if not section:
    return []
  return [line.strip() for line in section.split("\n") if line.strip().startswith("- ")]


def build_note(year, monday):
  prev_monday = monday - timedelta(days=7)
  prev_path = week_path(prev_monday)

  projects = get_active_projects()
  prev_next = get_prev_next_week(prev_path)
  q_goals = get_quarterly_goals(year, monday.month)

  # Merge: carry-forward items first, then quarterly goals not already listed
  next_week = list(prev_next)
  existing_text = " ".join(next_week).lower()
  for goal in q_goals:
    clean = goal.replace("- [ ] ", "").strip().lower()
    if clean[:30] not in existing_text:
      next_week.append(goal)

  projects_str = "\n".join(projects) if projects else ""
  next_week_str = "\n".join(next_week) if next_week else ""

  return f"""---
tags:
  - Calendar
hierarchy:
  - "[[{year}]]"
cssclasses: []
description:
---
↖ [[{year}]] 🗓️

## Projects
{projects_str}

## Highlights


## Blockers


## Next week
{next_week_str}

## Habit summary
```dataviewjs
const start = dv.current().file.cday;
const end = dv.date(start).plus({{days: 6}});
const days = dv.pages('"Calendar"')
  .where(p => p.file.name.match(/^\\d{{4}}-\\d{{2}}-\\d{{2}}$/) && p.file.cday >= start && p.file.cday <= end);

const moods = days.where(p => p.Mood).map(p => p.Mood);
if (moods.length > 0) {{
  const avg = (moods.reduce((a,b) => a+b, 0) / moods.length).toFixed(1);
  dv.paragraph(`**Avg mood:** ${{avg}}/5 (${{moods.length}} days tracked)`);
}} else {{
  dv.paragraph(`*No mood data this week*`);
}}
```

## Activity
```dataview
TABLE WITHOUT ID
  file.link AS "Note",
  dateformat(file.mtime, "ccc HH:mm") AS "Modified"
WHERE file.mtime >= (this.file.cday - dur(1 day))
  AND file.mtime <= (this.file.cday + dur(7 days))
  AND !contains(file.path, "Calendar/")
  AND !contains(file.path, "Extras/")
  AND !contains(file.path, ".obsidian/")
SORT file.mtime DESC
LIMIT 20
```

## Claude sessions
"""


def main():
  today = date.today()
  monday = today - timedelta(days=today.weekday())
  year = monday.isocalendar()[0]

  note_path = week_path(monday)

  if note_path.exists():
    log(f"Weekly note already exists: {note_path.name}")
    sys.exit(0)

  note_path.parent.mkdir(parents=True, exist_ok=True)
  content = build_note(year, monday)
  note_path.write_text(content)
  log(f"Created weekly note: {note_path.name}")


if __name__ == "__main__":
  main()
