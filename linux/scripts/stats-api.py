#!/usr/bin/env python3
"""Tiny stats API for Pi dashboard — serves /api/stats, /api/cron, /api/ntfy on port 9999."""

import json
import os
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
NTFY_TOPICS = ['pi-alerts', 'mac-alerts', 'openclaw', 'proxmox-alerts', 'arch-server-alerts']
NTFY_CACHE_DB = '/var/cache/ntfy/cache.db'



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

    def _handle_cron_list(self):
        try:
            with open(TASK_REGISTRY) as f:
                registry = json.load(f)
            hosts = []
            for host_entry in registry['hosts']:
                jobs = []
                for job in host_entry['jobs']:
                    jobs.append({
                        'id':          job['id'],
                        'name':        job['name'],
                        'schedule':    job['schedule'],
                        'description': job.get('description', ''),
                    })
                hosts.append({
                    'host': host_entry['host'],
                    'jobs': jobs,
                })
            self._send_json(200, {'hosts': hosts})
        except Exception as e:
            self._send_json(500, {'error': str(e)})

if __name__ == '__main__':
    server = HTTPServer(('127.0.0.1', 9999), Handler)
    print('Stats API running on http://127.0.0.1:9999')
    server.serve_forever()
