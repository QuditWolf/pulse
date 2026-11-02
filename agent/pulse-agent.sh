#!/usr/bin/env bash
# pulse agent: read CPU + GPU temps, push them to the pulse server. Run from cron every minute.
# Needs only bash, curl, and (optionally) nvidia-smi. Config: pulse-agent.env next to this script.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${PULSE_ENV:-$DIR/pulse-agent.env}"
: "${PULSE_URL:?set PULSE_URL}" "${PULSE_TOKEN:?set PULSE_TOKEN}"

metrics=()

# CPU: hottest sensor of the CPU hwmon driver (k10temp/zenpower on AMD, coretemp on Intel).
cpu_max=""
for hw in /sys/class/hwmon/hwmon*; do
  case "$(cat "$hw/name" 2>/dev/null)" in
    k10temp|zenpower|coretemp) ;;
    *) continue ;;
  esac
  for f in "$hw"/temp*_input; do
    [[ -r $f ]] || continue
    v=$(<"$f")
    [[ $v =~ ^[0-9]+$ ]] || continue
    if [[ -z $cpu_max || $v -gt $cpu_max ]]; then cpu_max=$v; fi
  done
done
if [[ -n $cpu_max ]]; then
  metrics+=("\"cpu\":$((cpu_max / 1000)).$(printf '%01d' $(((cpu_max % 1000) / 100)))")
fi

# GPUs: one metric per GPU (gpu0, gpu1, ...).
if command -v nvidia-smi >/dev/null 2>&1; then
  while IFS=', ' read -r idx temp; do
    [[ $idx =~ ^[0-9]+$ && $temp =~ ^[0-9]+$ ]] && metrics+=("\"gpu$idx\":$temp")
  done < <(timeout 15 nvidia-smi --query-gpu=index,temperature.gpu --format=csv,noheader,nounits 2>/dev/null || true)
fi

# The server rejects empty payloads, so fail loudly here instead (shows in cron mail / logs).
if ((${#metrics[@]} == 0)); then
  echo "pulse-agent: no temperature sensors found" >&2
  exit 1
fi

payload="{\"metrics\":{$(IFS=,; echo "${metrics[*]}")}}"
curl -fsS --max-time 15 --retry 2 --retry-delay 5 \
  -H "Authorization: Bearer $PULSE_TOKEN" \
  -H "Content-Type: application/json" \
  --data "$payload" \
  "${PULSE_URL%/}/ingest" >/dev/null
