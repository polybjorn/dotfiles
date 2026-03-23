#!/bin/bash
set -euo pipefail

APP_DIR="/var/www/hiking-map"
MAPS_DIR="$APP_DIR/gpx"
METADATA_FILE="$APP_DIR/metadata.json"
OUTPUT="$APP_DIR/routes.json"

if [[ ! -d "$MAPS_DIR" ]]; then
  echo "Error: $MAPS_DIR does not exist" >&2
  exit 1
fi

python3 - "$MAPS_DIR" "$METADATA_FILE" "$OUTPUT" <<'PYEOF'
import json, os, sys, xml.etree.ElementTree as ET
from datetime import datetime, timezone

maps_dir = sys.argv[1]
metadata_file = sys.argv[2]
output_file = sys.argv[3]

metadata = {}
if os.path.isfile(metadata_file):
    with open(metadata_file) as f:
        metadata = json.load(f)

def count_tracks(path):
    try:
        tree = ET.parse(path)
        root = tree.getroot()
        ns = root.tag.split('}')[0] + '}' if '}' in root.tag else ''
        return len(root.findall(f'.//{ns}trk'))
    except Exception:
        return 1

def has_elevation(path):
    with open(path, 'r', errors='replace') as f:
        for line in f:
            if '<ele>' in line:
                return True
    return False

regions = []
for region_name in sorted(os.listdir(maps_dir)):
    region_path = os.path.join(maps_dir, region_name)
    if not os.path.isdir(region_path) or region_name.startswith('.'):
        continue

    routes_map = {}
    for fname in os.listdir(region_path):
        if not fname.endswith('.gpx'):
            continue
        if fname.endswith('.planned.gpx'):
            base = fname[:-len('.planned.gpx')]
            routes_map.setdefault(base, {})['planned'] = fname
        else:
            base = fname[:-len('.gpx')]
            routes_map.setdefault(base, {})['walked'] = fname

    route_entries = []
    for base_name in sorted(routes_map.keys()):
        info = routes_map[base_name]
        walked = info.get('walked')
        planned = info.get('planned')
        completed = walked is not None
        primary = walked or planned
        primary_path = os.path.join(region_path, primary)

        route_key = f"{region_name}/{base_name}"
        entry = {
            'key': route_key,
            'file': f"{region_name}/{primary}",
            'name': base_name,
            'hasElevation': has_elevation(primary_path),
            'completed': completed,
        }

        if planned:
            entry['plannedFile'] = f"{region_name}/{planned}"

        tc = count_tracks(primary_path)
        if tc > 1:
            entry['trackCount'] = tc

        meta = metadata.get(route_key, {})
        for k, v in meta.items():
            if v:
                entry[k] = v

        route_entries.append(entry)

    regions.append({'name': region_name, 'routes': route_entries})

output = {
    'generated': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
    'regions': regions,
}

with open(output_file, 'w') as f:
    json.dump(output, f)

print(f"Generated {output_file}")
PYEOF
