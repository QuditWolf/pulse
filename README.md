# pulse

Lean temperature + online-status monitor.

```
[server] cron agent --HTTPS POST /pulse/ingest (bearer token)--> [VPS reverse proxy] --VPN--> [homeserver: pulse_server container]
browser --------------------- GET /pulse/ --------------------> [VPS reverse proxy] --VPN--> same container
```

- A host is **online** if it pushed within `PULSE_OFFLINE_AFTER` seconds (default 180). Gaps show as breaks in the graph.
- The token decides the host name; an agent cannot write as another host.
- Timestamps come from the server clock.
- Storage: one SQLite file, pruned after `PULSE_RETENTION_DAYS` (default 30).

## 1. Homeserver (container only)

```bash
git clone git@github.com:QuditWolf/pulse.git && cd pulse/server
cp .env.example .env && chmod 600 .env
openssl rand -hex 24          # token for each monitored server
$EDITOR .env                  # BIND_ADDR = homeserver VPN IP, PULSE_TOKENS, PULSE_PASSWORD
docker compose up -d --build
curl http://<vpn-ip>:5002/healthz        # {"ok":true}
```

Add a server later: append `,name=<token>` to `PULSE_TOKENS`, then `docker compose up -d`.
Update: `git pull && docker compose up -d --build` (data lives in the `pulse-data` volume).

## 2. VPS nginx

Paste `vps/nginx.conf` (one `location /pulse/` block) into the existing `server {}` for
`quditwolf.qutrit.org`, set the homeserver VPN IP, then `nginx -t && systemctl reload nginx`.
Page: `https://quditwolf.qutrit.org/pulse/` (browser asks for the password; any username).
`/pulse/ingest` uses the agent token instead, and `/pulse/healthz` is open.

## 3. Monitored server (cron, no install)

Reads the BMC `System Temp` sensor via `ipmitool` and pushes it as `system`.
Needs `bash`, `curl`, `ipmitool`, and one narrow sudo rule (cron cannot type a password):

```bash
echo "$USER ALL=(root) NOPASSWD: /usr/bin/ipmitool sdr type temperature" | sudo tee /etc/sudoers.d/pulse >/dev/null
sudo chmod 440 /etc/sudoers.d/pulse && sudo visudo -cf /etc/sudoers.d/pulse
```

Install (ENGG uses `~/scripts/pulse`):

```bash
mkdir -p ~/scripts/pulse && cp agent/pulse-agent.sh ~/scripts/pulse/
cp agent/pulse-agent.env.example ~/scripts/pulse/pulse-agent.env
chmod 600 ~/scripts/pulse/pulse-agent.env && $EDITOR ~/scripts/pulse/pulse-agent.env
~/scripts/pulse/pulse-agent.sh && echo ok    # first push, should appear on the page
( crontab -l 2>/dev/null; echo '* * * * * $HOME/scripts/pulse/pulse-agent.sh >/dev/null 2>>$HOME/scripts/pulse/agent.err' ) | crontab -
```

Different sensor name: set `PULSE_SENSOR="<name as in ipmitool>"` in the env file.

## API

| Method | Path | Notes |
|---|---|---|
| POST | `/ingest` | `Authorization: Bearer <token>`, body `{"metrics":{"system":37}}`, names `[a-z0-9_-]`, values -100..250, max 32 metrics |
| GET | `/api/status` | all hosts, online flag, latest values |
| GET | `/api/history?host=engg-ai-server&hours=24` | `hours` 1..168 |
| GET | `/healthz` | container healthcheck |

## Run locally

```bash
PULSE_DB=/tmp/t.db PULSE_TOKENS=dev=devtoken_0123456789 python3 server/app.py
```
