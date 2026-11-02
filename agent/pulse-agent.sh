#!/usr/bin/env bash
# pulse agent: read one BMC temperature sensor (default "System Temp") and its critical thresholds
# via ipmitool, push them to the pulse server. Run from cron every minute.
# Needs bash, curl, ipmitool, and a sudoers rule allowing exactly this read-only command:
#   <user> ALL=(root) NOPASSWD: /usr/bin/ipmitool sensor
# Config: pulse-agent.env next to this script.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${PULSE_ENV:-$DIR/pulse-agent.env}"
: "${PULSE_URL:?set PULSE_URL}" "${PULSE_TOKEN:?set PULSE_TOKEN}"
SENSOR="${PULSE_SENSOR:-System Temp}"
METRIC="${PULSE_METRIC:-system}"

# `ipmitool sensor` columns: name | value | unit | status | LNR | LCR | LNC | UNC | UCR | UNR
# We report the value and the critical range LCR..UCR.
read -r value lcr ucr < <(timeout 20 sudo -n /usr/bin/ipmitool sensor \
  | awk -F'|' -v s="$SENSOR" '
      { for (i = 1; i <= NF; i++) gsub(/^ +| +$/, "", $i) }
      $1 == s { print $2, $6, $9; exit }') || true

num='^-?[0-9]+(\.[0-9]+)?$'
if [[ ! ${value:-} =~ $num ]]; then
  echo "pulse-agent: no reading for '$SENSOR' (got '${value:-}')" >&2
  exit 1
fi

limits=""
if [[ ${lcr:-} =~ $num && ${ucr:-} =~ $num ]]; then
  limits=",\"limits\":{\"$METRIC\":[$lcr,$ucr]}"
fi

curl -fsS --max-time 15 --retry 2 --retry-delay 5 \
  -H "Authorization: Bearer $PULSE_TOKEN" \
  -H "Content-Type: application/json" \
  --data "{\"metrics\":{\"$METRIC\":$value}$limits}" \
  "${PULSE_URL%/}/ingest" >/dev/null
