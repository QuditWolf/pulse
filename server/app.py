#!/usr/bin/env python3
"""pulse server: receives temperature pushes, stores them in SQLite, serves a status page.

Stdlib only. Config via environment:
  PULSE_TOKENS          "host1=token1,host2=token2"  (token decides which host a push belongs to)
  PULSE_DB              SQLite path (default /data/pulse.db)
  PULSE_PORT            listen port (default 8080)
  PULSE_OFFLINE_AFTER   seconds without a push before a host counts as offline (default 180)
  PULSE_RETENTION_DAYS  days of history to keep (default 30)
  PULSE_PASSWORD        if set, the API needs a login (in-page form) with this password
"""
import hashlib
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
SESSION_DAYS = 30
COOKIE = "pulse_session"
# Crude brute-force brake: at most this many failed logins per minute, across all clients.
MAX_FAILS_PER_MIN = 10
_fails = []
_fails_lock = threading.Lock()


def _sign(exp):
    return hmac.new(PASSWORD.encode(), f"pulse-session:{exp}".encode(), "sha256").hexdigest()


def make_session():
    exp = int(time.time()) + SESSION_DAYS * 86400
    return f"{exp}.{_sign(exp)}"


def valid_session(value):
    exp, _, sig = value.partition(".")
    return exp.isdigit() and int(exp) > time.time() and hmac.compare_digest(sig, _sign(int(exp)))


def login_allowed():
    now = time.time()
    with _fails_lock:
        _fails[:] = [t for t in _fails if now - t < 60]
        return len(_fails) < MAX_FAILS_PER_MIN


def record_fail():
    with _fails_lock:
        _fails.append(time.time())

MAX_BODY = 16384
MAX_METRICS = 128
MAX_HOURS = 24 * 7
NAME_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,31}$")
INDEX_HTML = (Path(__file__).parent / "index.html").read_bytes()
# Open pages compare this and reload themselves after a deploy.
UI_VERSION = hashlib.sha256(INDEX_HTML).hexdigest()[:12]


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
            if "metric_order" not in cols:
                self.db.execute("ALTER TABLE hosts ADD COLUMN metric_order TEXT")

    def insert(self, host, ts, metrics, limits):
        with self.lock:
            self.db.execute("BEGIN")
            self.db.executemany(
                "INSERT INTO samples VALUES (?, ?, ?, ?)", [(host, ts, k, v) for k, v in metrics.items()]
            )
            self.db.execute(
                "INSERT INTO hosts (host, last_seen, limits, metric_order) VALUES (?, ?, ?, ?) "
                "ON CONFLICT(host) DO UPDATE SET last_seen = excluded.last_seen, limits = excluded.limits, "
                "metric_order = excluded.metric_order",
                (host, ts, json.dumps(limits), json.dumps(list(metrics))),
            )
            self.db.execute("COMMIT")

    def status(self, now):
        with self.lock:
            hosts = self.db.execute("SELECT host, last_seen, limits, metric_order FROM hosts ORDER BY host").fetchall()
            out = []
            for host, last_seen, limits, order in hosts:
                rows = self.db.execute(
                    "SELECT metric, value FROM samples WHERE host = ? AND ts = ?", (host, last_seen)
                ).fetchall()
                out.append({
                    "host": host,
                    "last_seen": last_seen,
                    "online": now - last_seen <= OFFLINE_AFTER,
                    "latest": dict(rows),
                    "limits": json.loads(limits or "{}"),
                    # Order the agent sent them in; the first one is the page's default.
                    "order": [m for m in json.loads(order or "[]") if m in dict(rows)] or sorted(dict(rows)),
                })
        # Hosts configured but never seen still show up, as offline.
        seen = {h["host"] for h in out}
        out += [{"host": h, "last_seen": None, "online": False, "latest": {}, "limits": {}, "order": []} for h in sorted(TOKENS) if h not in seen]
        return out

    def history(self, host, since, only=None):
        sql = "SELECT ts, metric, value FROM samples WHERE host = ? AND ts >= ?"
        args = [host, since]
        if only:
            sql += f" AND metric IN ({','.join('?' * len(only))})"
            args += only
        with self.lock:
            rows = self.db.execute(sql + " ORDER BY ts", args).fetchall()
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
        raise ValueError(f"need 'metrics' object with 1..{MAX_METRICS} entries")
    clean = {}
    for k, v in metrics.items():
        if not isinstance(k, str) or not NAME_RE.match(k):
            raise ValueError(f"bad metric name {k!r}")
        if isinstance(v, bool) or not isinstance(v, (int, float)) or not math.isfinite(v) or not -100 <= v <= 250:
            raise ValueError(f"bad value for {k}")
        clean[k] = round(float(v), 2)
    # Optional per-metric safe range as reported by the sensor, e.g. {"system": [5, 85]}; either end may be null.
    limits = {}
    raw = data.get("limits") or {}
    if not isinstance(raw, dict):
        raise ValueError("'limits' must be an object")
    for k, rng in raw.items():
        if k not in clean or not isinstance(rng, list) or len(rng) != 2 or not all(
            x is None or (isinstance(x, (int, float)) and not isinstance(x, bool) and math.isfinite(x) and -100 <= x <= 250)
            for x in rng
        ) or rng == [None, None]:
            raise ValueError(f"bad limits for {k!r}")
        limits[k] = [None if x is None else float(x) for x in rng]
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
        for part in self.headers.get("Cookie", "").split(";"):
            name, _, value = part.strip().partition("=")
            if name == COOKIE and valid_session(value):
                return True
        return False

    def _cookie(self, value, max_age):
        return f"{COOKIE}={value}; Max-Age={max_age}; HttpOnly; Secure; SameSite=Strict"

    def _read_body(self):
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            return None
        return self.rfile.read(length) if 0 < length <= MAX_BODY else None

    def _login(self):
        if not PASSWORD:
            return self._send(200, {"ok": True})
        if not login_allowed():
            return self._send(429, {"error": "too many attempts, wait a minute"})
        body = self._read_body()
        try:
            pw = json.loads(body).get("password", "") if body else ""
        except (ValueError, AttributeError):
            pw = ""
        if not isinstance(pw, str) or not hmac.compare_digest(pw.encode(), PASSWORD.encode()):
            record_fail()
            return self._send(401, {"error": "wrong password"})
        body = b'{"ok":true}'
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Set-Cookie", self._cookie(make_session(), SESSION_DAYS * 86400))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        url = urlparse(self.path)
        if url.path == "/healthz":
            return self._send(200, {"ok": True})
        if url.path == "/":
            # The page itself holds no data; it shows a login form until the API accepts it.
            return self._send(200, INDEX_HTML, "text/html; charset=utf-8", "no-cache")
        if not self._authorized():
            return self._send(401, {"error": "login required"})
        if url.path == "/api/status":
            return self._send(200, {"now": int(time.time()), "offline_after": OFFLINE_AFTER, "ui": UI_VERSION,
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
            only = [m for m in q.get("metrics", [""])[0].split(",") if m]
            if len(only) > MAX_METRICS or not all(NAME_RE.match(m) for m in only):
                return self._send(400, {"error": "bad metrics"})
            return self._send(200, STORE.history(host, int(time.time()) - hours * 3600, only))
        self._send(404, {"error": "not found"})

    def do_POST(self):
        path = urlparse(self.path).path
        if path == "/login":
            return self._login()
        if path == "/logout":
            self.send_response(204)
            self.send_header("Set-Cookie", self._cookie("", 0))
            self.end_headers()
            return
        if path != "/ingest":
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
