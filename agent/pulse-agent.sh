#!/usr/bin/env bash
# pulse agent: read the BMC "System Temp" sensor via ipmitool and push it to the pulse server.
# Run from cron every minute. Needs bash, curl, ipmitool, and a sudoers rule:
#   <user> ALL=(root) NOPASSWD: /usr/bin/ipmitool sdr type temperature
# Config: pulse-agent.env next to this script.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${PULSE_ENV:-$DIR/pulse-agent.env}"
: "${PULSE_URL:?set PULSE_URL}" "${PULSE_TOKEN:?set PULSE_TOKEN}"
SENSOR="${PULSE_SENSOR:-System Temp}"

# Line format: "System Temp      | 30h | ok  |  7.1 | 32 degrees C"
temp=$(timeout 20 sudo -n /usr/bin/ipmitool sdr type temperature \
  | awk -F'|' -v s="$SENSOR" '{n=$1; gsub(/^ +| +$/, "", n)} n == s {split($5, a, " "); print a[1]; exit}')

if [[ ! $temp =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
  echo "pulse-agent: no reading for '$SENSOR' (got '${temp}')" >&2
  exit 1
fi

curl -fsS --max-time 15 --retry 2 --retry-delay 5 \
  -H "Authorization: Bearer $PULSE_TOKEN" \
  -H "Content-Type: application/json" \
  --data "{\"metrics\":{\"system\":$temp}}" \
  "${PULSE_URL%/}/ingest" >/dev/null
