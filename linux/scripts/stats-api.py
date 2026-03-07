#!/usr/bin/env python3
"""Tiny stats API for Pi dashboard — serves /api/stats, /api/cron, /api/ntfy on port 9999."""

import json
import os
import re
import sqlite3
import subprocess
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from urllib.request import Request, urlopen

TASK_REGISTRY = '/usr/local/lib/pi-cron/cron-registry.json'
import pwd as _pwd
_script_owner_uid = os.stat(os.path.realpath(__file__)).st_uid
_user_home = _pwd.getpwuid(_script_owner_uid).pw_dir
BACKUP_DIR = Path(f'{_user_home}/backups/{os.uname().nodename}')
MAC_STATS_FILE = '/var/www/pi-dashboard/mac-stats.json'
MAC_OFFLINE_SECONDS = 300
ST_API = 'http://localhost:8384'
NTFY_URL = 'http://localhost:2586'
NTFY_TOPICS = ['pi-alerts', 'mac-alerts', 'openclaw']
NTFY_CACHE_DB = '/var/cache/ntfy/cache.db'
VALID_JOB_ID = re.compile(r'^[a-z0-9-]+$')

def relative_time(seconds):
    """Format seconds-ago as human-readable relative time."""
    if seconds < 60:
        return "just now"
    minutes = int(seconds // 60)
    if minutes < 60:
        return f"{minutes}m ago"
    hours = int(seconds // 3600)
    if hours < 24:
        return f"{hours}h ago"
    days = int(seconds // 86400)
    return f"{days}d ago"

def timer_is_enabled(timer_unit):
    """Check if a systemd timer is enabled."""
    result = subprocess.run(
        ['systemctl', 'is-enabled', timer_unit],
        capture_output=True, text=True
    )
    return result.stdout.strip() == 'enabled'

def timer_toggle(timer_unit, enable):
    """Enable or disable a systemd timer."""
    action = 'enable' if enable else 'disable'
    subprocess.run(
        ['sudo', 'systemctl', action, timer_unit],
        capture_output=True, text=True, timeout=10, check=True
    )

def get_job_detail(job_id):
    """Get a short detail string for a specific job, or None."""
    try:
        if job_id == 'health-check':
            result = subprocess.run(
                ['journalctl', '-u', 'health-check.service', '-n', '1', '--no-pager', '-q', '-o', 'short-iso'],
                capture_output=True, text=True, timeout=5
            )
            if result.stdout.strip():
                line = result.stdout.strip().split('\n')[-1]
                ts = line.split(' ')[0] if line else None
                if ts:
                    from datetime import datetime, timezone
                    try:
                        dt = datetime.fromisoformat(ts)
                        age = (datetime.now(timezone.utc) - dt.astimezone(timezone.utc)).total_seconds()
                        return relative_time(age)
                    except Exception:
                        return ts
            return None

    except:
        pass
    return None

def get_ntfy_data():
    """Fetch topic stats and recent messages from ntfy."""
    try:
        topics = []
        all_messages = []
        for topic in NTFY_TOPICS:
            url = f'{NTFY_URL}/{topic}/json?poll=1&since=48h'
            req = Request(url)
            try:
                with urlopen(req, timeout=3) as resp:
                    lines = resp.read().decode().strip().split('\n')
                msgs = [json.loads(l) for l in lines if l.strip()] if lines[0] else []
            except Exception:
                msgs = []
            topics.append({
                'name': topic,
                'count': len(msgs),
                'last': msgs[-1]['time'] if msgs else None,
            })
            all_messages.extend(msgs)
        # Sort by time descending, take last 8
        all_messages.sort(key=lambda m: m.get('time', 0), reverse=True)
        recent = []
        for m in all_messages[:8]:
            recent.append({
                'title': m.get('title', ''),
                'message': m.get('message', ''),
                'topic': m.get('topic', ''),
                'time': m.get('time', 0),
                'priority': m.get('priority', 3),
                'tags': m.get('tags', []),
            })
        return {'topics': topics, 'messages': recent}
    except Exception:
        return {'topics': [], 'messages': []}

def get_mac_stats():
    try:
        mtime = os.path.getmtime(MAC_STATS_FILE)
        age = time.time() - mtime
        if age > MAC_OFFLINE_SECONDS:
            return {"offline": True, "age": round(age)}
        with open(MAC_STATS_FILE) as f:
            data = json.load(f)
        data["age"] = round(age)
        data["offline"] = False
        return data
    except (FileNotFoundError, json.JSONDecodeError):
        return {"offline": True}

def get_temp():
    try:
        out = subprocess.check_output(['/usr/bin/vcgencmd', 'measure_temp'], text=True)
        return out.strip().replace("temp=", "").replace("'C", "")
    except:
        try:
            with open('/sys/class/thermal/thermal_zone0/temp') as f:
                return str(int(f.read().strip()) / 1000)
        except:
            return None

def get_cpu():
    try:
        with open('/proc/stat') as f:
            fields = list(map(int, f.readline().split()[1:]))
        idle = fields[3]
        total = sum(fields)
        import time; time.sleep(0.5)
        with open('/proc/stat') as f:
            fields2 = list(map(int, f.readline().split()[1:]))
        idle2 = fields2[3]
        total2 = sum(fields2)
        return round(100 * (1 - (idle2 - idle) / (total2 - total)), 1)
    except:
        return None

def get_mem():
    try:
        with open('/proc/meminfo') as f:
            lines = {line.split(':')[0]: int(line.split()[1]) for line in f}
        total = lines['MemTotal'] // 1024
        available = lines['MemAvailable'] // 1024
        used = total - available
        return used, total
    except:
        return None, None

def get_uptime():
    try:
        with open('/proc/uptime') as f:
            seconds = float(f.read().split()[0])
        days    = int(seconds // 86400)
        hours   = int((seconds % 86400) // 3600)
        minutes = int((seconds % 3600) // 60)
        if days > 0:
            return f"{days}d {hours}h"
        elif hours > 0:
            return f"{hours}h {minutes}m"
        else:
            return f"{minutes}m"
    except:
        return None

def get_disk():
    try:
        st = os.statvfs('/')
        total = st.f_frsize * st.f_blocks
        free = st.f_frsize * st.f_bavail
        used = total - free
        return {
            'used':  round(used / 1_073_741_824, 1),
            'total': round(total / 1_073_741_824, 1),
            'pct':   round(used / total * 100, 1),
        }
    except:
        return None

def get_backup_status():
    try:
        tarballs = sorted(BACKUP_DIR.glob('*.tar.gz'), key=lambda p: p.name, reverse=True)
        if not tarballs:
            return None
        latest = tarballs[0]
        size = latest.stat().st_size
        age_hours = round((time.time() - latest.stat().st_mtime) / 3600, 1)
        if size >= 1_073_741_824:
            size_str = f"{size / 1_073_741_824:.1f} GB"
        elif size >= 1_048_576:
            size_str = f"{size / 1_048_576:.0f} MB"
        else:
            size_str = f"{size / 1024:.0f} KB"
        return {
            'age_hours': age_hours,
            'size':      size_str,
            'count':     len(tarballs),
        }
    except:
        return None

def get_syncthing_devices():
    try:
        api_key = os.environ.get('SYNCTHING_API_KEY')
        if not api_key:
            return None
        # Get device list from Syncthing API
        def st_get(path):
            req = Request(f'{ST_API}{path}', headers={'X-API-Key': api_key})
            with urlopen(req, timeout=3) as resp:
                return json.loads(resp.read())
        config = st_get('/rest/config')
        conns = st_get('/rest/system/connections')['connections']
        my_id = st_get('/rest/system/status')['myID']
        result = []
        for dev in sorted(config['devices'], key=lambda d: d['name']):
            did = dev['deviceID']
            if did == my_id:
                continue
            connected = conns.get(did, {}).get('connected', False)
            result.append({'name': dev['name'], 'connected': connected})
        return result
    except:
        return None

class Handler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass  # silence request logs

    def _send_json(self, code, data):
        body = json.dumps(data).encode()
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Access-Control-Allow-Origin', '*')
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == '/api/stats':
            mem_used, mem_total = get_mem()
            data = {
                'temp':      get_temp(),
                'uptime':    get_uptime(),
                'cpu':       get_cpu(),
                'mem_used':  mem_used,
                'mem_total': mem_total,
                'disk':      get_disk(),
                'backup':    get_backup_status(),
                'syncthing': get_syncthing_devices(),
            }
            self._send_json(200, data)

        elif self.path == '/api/cron':
            self._handle_cron_list()

        elif self.path == '/api/mac-stats':
            self._send_json(200, get_mac_stats())

        elif self.path == '/api/ntfy':
            self._send_json(200, get_ntfy_data())

        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        if self.path == '/api/ntfy/clear':
            self._handle_ntfy_clear()
            return
        m = re.match(r'^/api/cron/([a-z0-9-]+)/(enable|disable)$', self.path)
        if m:
            job_id, action = m.group(1), m.group(2)
            self._handle_cron_toggle(job_id, action)
        else:
            self.send_response(404)
            self.end_headers()

    def _handle_ntfy_clear(self):
        try:
            topics_clause = ','.join('?' for _ in NTFY_TOPICS)
            conn = sqlite3.connect(NTFY_CACHE_DB)
            cur = conn.execute(
                f'DELETE FROM messages WHERE topic IN ({topics_clause})',
                NTFY_TOPICS,
            )
            deleted = cur.rowcount
            conn.commit()
            conn.close()
            self._send_json(200, {'deleted': deleted})
        except Exception as e:
            self._send_json(500, {'error': str(e)})

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', 'Content-Type')
        self.end_headers()

    @staticmethod
    def _get_timers(job):
        """Get timer unit(s) for a job — supports grouped timers."""
        return job.get('timers', [job['id'] + '.timer'])

    def _handle_cron_list(self):
        try:
            with open(TASK_REGISTRY) as f:
                registry = json.load(f)
            jobs = []
            for job in registry['jobs']:
                timers = self._get_timers(job)
                enabled = all(timer_is_enabled(t) for t in timers)
                entry = {
                    'id':          job['id'],
                    'name':        job['name'],
                    'schedule':    job['schedule'],
                    'enabled':     enabled,
                }
                if 'icon' in job:
                    entry['icon'] = job['icon']
                if 'description' in job:
                    entry['description'] = job['description']
                detail = get_job_detail(job['id'])
                if detail:
                    entry['detail'] = detail
                jobs.append(entry)
            self._send_json(200, {'jobs': jobs})
        except Exception as e:
            self._send_json(500, {'error': str(e)})

    def _handle_cron_toggle(self, job_id, action):
        if not VALID_JOB_ID.match(job_id):
            self._send_json(400, {'error': 'Invalid job ID'})
            return
        try:
            with open(TASK_REGISTRY) as f:
                registry = json.load(f)
            job = next((j for j in registry['jobs'] if j['id'] == job_id), None)
            if not job:
                self._send_json(400, {'error': 'Unknown job ID'})
                return
            timers = self._get_timers(job)
            for t in timers:
                timer_toggle(t, action == 'enable')
            enabled = all(timer_is_enabled(t) for t in timers)
            self._send_json(200, {'enabled': enabled})
        except Exception as e:
            self._send_json(500, {'error': str(e)})

if __name__ == '__main__':
    server = HTTPServer(('127.0.0.1', 9999), Handler)
    print('Stats API running on http://127.0.0.1:9999')
    server.serve_forever()
