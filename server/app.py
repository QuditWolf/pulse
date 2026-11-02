#!/usr/bin/env python3
"""pulse server: receives temperature pushes, stores them in SQLite, serves a status page.

Stdlib only. Config via environment:
  PULSE_TOKENS          "host1=token1,host2=token2"  (token decides which host a push belongs to)
  PULSE_DB              SQLite path (default /data/pulse.db)
  PULSE_PORT            listen port (default 8080)
  PULSE_OFFLINE_AFTER   seconds without a push before a host counts as offline (default 180)
  PULSE_RETENTION_DAYS  days of history to keep (default 30)
  PULSE_PASSWORD        if set, page + API need HTTP Basic auth with this password (any username)
"""
import base64
import hmac
import json
import math
import os
import re
import sqlite3
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

DB_PATH = os.environ.get("PULSE_DB", "/data/pulse.db")
PORT = int(os.environ.get("PULSE_PORT", "8080"))
OFFLINE_AFTER = int(os.environ.get("PULSE_OFFLINE_AFTER", "180"))
RETENTION_DAYS = int(os.environ.get("PULSE_RETENTION_DAYS", "30"))
PASSWORD = os.environ.get("PULSE_PASSWORD", "")

MAX_BODY = 4096
MAX_METRICS = 32
MAX_HOURS = 24 * 7
NAME_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,31}$")
INDEX_HTML = (Path(__file__).parent / "index.html").read_bytes()


def load_tokens():
    tokens = {}
    for pair in filter(None, (p.strip() for p in os.environ.get("PULSE_TOKENS", "").split(","))):
        host, sep, token = pair.partition("=")
        host, token = host.strip(), token.strip()
        if not sep or not NAME_RE.match(host) or len(token) < 16:
            sys.exit(f"bad PULSE_TOKENS entry for {host!r}: need host=token, token >= 16 chars")
        tokens[host] = token
    if not tokens:
        print("warning: PULSE_TOKENS empty, no host can push", file=sys.stderr)
    return tokens


TOKENS = load_tokens()


class Store:
    def __init__(self, path):
        Path(path).parent.mkdir(parents=True, exist_ok=True)
        self.db = sqlite3.connect(path, check_same_thread=False, isolation_level=None)
        self.lock = threading.Lock()
        with self.lock:
            self.db.execute("PRAGMA journal_mode=WAL")
            self.db.execute(
                "CREATE TABLE IF NOT EXISTS samples (host TEXT, ts INTEGER, metric TEXT, value REAL)"
            )
            self.db.execute("CREATE INDEX IF NOT EXISTS samples_host_ts ON samples (host, ts)")
            self.db.execute("CREATE TABLE IF NOT EXISTS hosts (host TEXT PRIMARY KEY, last_seen INTEGER)")
            cols = {r[1] for r in self.db.execute("PRAGMA table_info(hosts)")}
            if "limits" not in cols:
                self.db.execute("ALTER TABLE hosts ADD COLUMN limits TEXT")

    def insert(self, host, ts, metrics, limits):
        with self.lock:
            self.db.execute("BEGIN")
            self.db.executemany(
                "INSERT INTO samples VALUES (?, ?, ?, ?)", [(host, ts, k, v) for k, v in metrics.items()]
            )
            self.db.execute(
                "INSERT INTO hosts (host, last_seen, limits) VALUES (?, ?, ?) "
                "ON CONFLICT(host) DO UPDATE SET last_seen = excluded.last_seen, limits = excluded.limits",
                (host, ts, json.dumps(limits)),
            )
            self.db.execute("COMMIT")

    def status(self, now):
        with self.lock:
            hosts = self.db.execute("SELECT host, last_seen, limits FROM hosts ORDER BY host").fetchall()
            out = []
            for host, last_seen, limits in hosts:
                rows = self.db.execute(
                    "SELECT metric, value FROM samples WHERE host = ? AND ts = ?", (host, last_seen)
                ).fetchall()
                out.append({
                    "host": host,
                    "last_seen": last_seen,
                    "online": now - last_seen <= OFFLINE_AFTER,
                    "latest": dict(rows),
                    "limits": json.loads(limits or "{}"),
                })
        # Hosts configured but never seen still show up, as offline.
        seen = {h["host"] for h in out}
        out += [{"host": h, "last_seen": None, "online": False, "latest": {}, "limits": {}} for h in sorted(TOKENS) if h not in seen]
        return out

    def history(self, host, since):
        with self.lock:
            rows = self.db.execute(
                "SELECT ts, metric, value FROM samples WHERE host = ? AND ts >= ? ORDER BY ts", (host, since)
            ).fetchall()
        metrics = sorted({m for _, m, _ in rows})
        by_ts = {}
        for ts, m, v in rows:
            by_ts.setdefault(ts, {})[m] = v
        times, series = [], {m: [] for m in metrics}
        prev = None
        for ts in sorted(by_ts):
            # Insert a null point across gaps so the chart shows downtime instead of a straight line.
            if prev is not None and ts - prev > OFFLINE_AFTER:
                times.append(prev + 1)
                for m in metrics:
                    series[m].append(None)
            times.append(ts)
            for m in metrics:
                series[m].append(by_ts[ts].get(m))
            prev = ts
        return {"host": host, "ts": times, "series": series}

    def prune(self, before):
        with self.lock:
            self.db.execute("DELETE FROM samples WHERE ts < ?", (before,))


STORE = Store(DB_PATH)


def parse_metrics(body):
    data = json.loads(body)
    metrics = data.get("metrics") if isinstance(data, dict) else None
    if not isinstance(metrics, dict) or not 0 < len(metrics) <= MAX_METRICS:
        raise ValueError("need 'metrics' object with 1..32 entries")
    clean = {}
    for k, v in metrics.items():
        if not isinstance(k, str) or not NAME_RE.match(k):
            raise ValueError(f"bad metric name {k!r}")
        if isinstance(v, bool) or not isinstance(v, (int, float)) or not math.isfinite(v) or not -100 <= v <= 250:
            raise ValueError(f"bad value for {k}")
        clean[k] = round(float(v), 2)
    # Optional per-metric safe range as reported by the sensor, e.g. {"system": [5, 85]}.
    limits = {}
    raw = data.get("limits") or {}
    if not isinstance(raw, dict):
        raise ValueError("'limits' must be an object")
    for k, rng in raw.items():
        if k not in clean or not isinstance(rng, list) or len(rng) != 2 or not all(
            isinstance(x, (int, float)) and not isinstance(x, bool) and math.isfinite(x) and -100 <= x <= 250
            for x in rng
        ):
            raise ValueError(f"bad limits for {k!r}")
        limits[k] = [float(rng[0]), float(rng[1])]
    return clean, limits


class Handler(BaseHTTPRequestHandler):
    server_version = "pulse"
    sys_version = ""

    def log_message(self, fmt, *args):
        pass  # keep container logs quiet; errors still go to stderr via send_error paths below

    def _send(self, code, body, ctype="application/json", cache="no-store"):
        if not isinstance(body, bytes):
            body = json.dumps(body, separators=(",", ":")).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", cache)
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(body)

    def _authorized(self):
        if not PASSWORD:
            return True
        auth = self.headers.get("Authorization", "")
        if not auth.startswith("Basic "):
            return False
        try:
            _, _, pw = base64.b64decode(auth[6:]).decode().partition(":")
        except ValueError:
            return False
        return hmac.compare_digest(pw.encode(), PASSWORD.encode())

    def do_GET(self):
        url = urlparse(self.path)
        if url.path == "/healthz":
            return self._send(200, {"ok": True})
        if not self._authorized():
            self.send_response(401)
            self.send_header("WWW-Authenticate", 'Basic realm="pulse"')
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if url.path == "/":
            return self._send(200, INDEX_HTML, "text/html; charset=utf-8", "max-age=60")
        if url.path == "/api/status":
            return self._send(200, {"now": int(time.time()), "offline_after": OFFLINE_AFTER,
                                    "hosts": STORE.status(int(time.time()))})
        if url.path == "/api/history":
            q = parse_qs(url.query)
            host = q.get("host", [""])[0]
            try:
                hours = min(max(int(q.get("hours", ["24"])[0]), 1), MAX_HOURS)
            except ValueError:
                return self._send(400, {"error": "bad hours"})
            if not NAME_RE.match(host):
                return self._send(400, {"error": "bad host"})
            return self._send(200, STORE.history(host, int(time.time()) - hours * 3600))
        self._send(404, {"error": "not found"})

    def do_POST(self):
        if urlparse(self.path).path != "/ingest":
            return self._send(404, {"error": "not found"})
        auth = self.headers.get("Authorization", "")
        token = auth[7:] if auth.startswith("Bearer ") else ""
        host = next((h for h, t in TOKENS.items() if hmac.compare_digest(t.encode(), token.encode())), None)
        if not host:
            return self._send(401, {"error": "unauthorized"})
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            length = -1
        if not 0 < length <= MAX_BODY:
            return self._send(413, {"error": "body too large or empty"})
        try:
            metrics, limits = parse_metrics(self.rfile.read(length))
        except (ValueError, json.JSONDecodeError) as e:
            return self._send(400, {"error": str(e)})
        # Server clock is the source of truth; agent clocks may drift.
        STORE.insert(host, int(time.time()), metrics, limits)
        self._send(200, {"ok": True, "host": host})


def pruner():
    while True:
        try:
            STORE.prune(int(time.time()) - RETENTION_DAYS * 86400)
        except Exception as e:  # never let the pruner die
            print(f"prune failed: {e}", file=sys.stderr)
        time.sleep(3600)


if __name__ == "__main__":
    threading.Thread(target=pruner, daemon=True).start()
    srv = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    print(f"pulse listening on :{PORT}, hosts: {', '.join(sorted(TOKENS)) or '(none)'}", flush=True)
    srv.serve_forever()
