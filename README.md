# pulse

Lean temperature, usage + online-status monitor.

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
Page: `https://quditwolf.qutrit.org/pulse/` (in-page login form; session cookie lasts 30 days).
`/pulse/ingest` uses the agent token instead, and `/pulse/healthz` is open.

## 3. Monitored server (cron, no install)

Pushes every temperature the host exposes, each with its own limits:

| Source | Metric names | Limits |
|---|---|---|
| `ipmitool sensor` (BMC) | `system`, `cpu`, `gpu3`, `dimma_f`, … | LCR..UCR (fallback LNR..UNR) |
| `/sys/class/hwmon` (same data `lm-sensors` reads) | `k10temp_tctl`, `nvme_composite`, … | min/lcrit..crit/max when the driver sets them |
| `nvidia-smi` | `nvidia_gpu0`, … | current + `tlimit` headroom (max operating temp) |

Plus usage, from `/proc` and `nvidia-smi`:

| Metric | Meaning |
|---|---|
| `cpu_pct` | CPU busy time across all cores since the previous push |
| `mem_pct` | RAM in use, page cache excluded (limit 90) |
| `load_pct` | 1-min load average ÷ cores (100 = every core has work; above = tasks waiting) |
| `gpu_pct`, `vram_pct` | GPU busy time and memory allocated, averaged over all GPUs; `gpu<N>_pct`, `gpu<N>_vram_pct` per GPU on multi-GPU hosts |
| `disk_busy_pct` | share of time the busiest physical disk had I/O in flight |
| `disk_read_mbs`, `disk_write_mbs` | MB/s summed over physical disks |

Uptime, cores, RAM size and raw load 1/5/15 go as `info` and show as a text line. CPU and disk figures are deltas
against a state file (`.pulse-state` next to the script), so the first push after install has none of them.

The page draws one chart per kind (temperature °C, usage %, disk MB/s), each with a caption saying what the range means.
It shows the host's `PULSE_DEFAULTS` plus the usage aggregates by default; tick other metrics under "Sensors" on each
host card (remembered per browser). Readings outside their limits turn red. Missing sources are skipped.

Needs `bash`, `curl`, `awk`; for BMC sensors also `ipmitool` and one narrow sudo rule (cron cannot type a password):

```bash
echo "$USER ALL=(root) NOPASSWD: /usr/bin/ipmitool sensor" | sudo tee /etc/sudoers.d/pulse >/dev/null
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

No cron (e.g. Arch)? As root, install as a systemd timer under `/opt/pulse-agent` (rerun without vars to update the script):

```bash
curl -fsSL https://raw.githubusercontent.com/QuditWolf/pulse/main/agent/install-systemd.sh \
  | PULSE_URL=https://quditwolf.qutrit.org/pulse PULSE_TOKEN=<token> bash
```

Check what a host exposes first: `curl -fsSL https://raw.githubusercontent.com/QuditWolf/pulse/main/agent/pulse-probe.sh | bash` (read-only).

The sudo rule allows exactly `ipmitool sensor` with no arguments, a read-only listing; `ipmitool sensor thresh …` stays blocked.

## API

| Method | Path | Notes |
|---|---|---|
| POST | `/ingest` | `Authorization: Bearer <token>`, body `{"metrics":{"system":37},"limits":{"system":[5,85]}}` (`limits`, `defaults`, `info` optional), names `[a-z0-9_-]`, values -100..100000, max 192 metrics; either limit may be `null`. Names ending `_pct` are percent, `_mbs` MB/s, others °C |
| GET | `/api/status` | all hosts, online flag, latest values |
| GET | `/api/history?host=engg-ai-server&hours=24&metrics=system,gpu3` | `hours` 1..168, `metrics` optional filter |
| GET | `/healthz` | container healthcheck |

## Run locally

```bash
PULSE_DB=/tmp/t.db PULSE_TOKENS=dev=devtoken_0123456789 python3 server/app.py
```
