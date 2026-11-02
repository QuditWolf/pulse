#!/usr/bin/env bash
# pulse agent: collect every temperature the host exposes and push it to the pulse server.
# Run from cron every minute. Needs bash, curl, awk; optional sources are skipped if missing.
#
# Sources and metric names:
#   ipmitool sensor (BMC)   -> "system", "cpu", "gpu3", "dimma_f", ...   limits: LCR..UCR (fallback LNR..UNR)
#   /sys/class/hwmon        -> "<driver>_<label>", e.g. "k10temp_tctl", "nvme_composite"   limits: min/lcrit..crit/max
#                              drivers with several instances get a number: "coretemp_0_core_0", "coretemp_1_core_0"
#   nvidia-smi              -> "nvidia_gpu<N>"   limit: current + tlimit headroom (max operating temp)
#                              plus "nvidia_gpu_max" (hottest GPU) when there is more than one GPU
# (lm-sensors' `sensors` reads the same /sys/class/hwmon data, so it is not needed.)
#
# ipmitool needs root; allow exactly this read-only command in sudoers:
#   <user> ALL=(root) NOPASSWD: /usr/bin/ipmitool sensor
# Config: pulse-agent.env next to this script.
#   PULSE_URL, PULSE_TOKEN   required
#   PULSE_DEFAULTS           optional comma list of metrics the page shows by default, e.g.
#                            "system,cpu,nvidia_gpu0". They are sent first, in this order. Without it the
#                            page shows only the first metric sent (order: ipmitool, hwmon, nvidia-smi).
#   PULSE_FIRST              older single-metric form of PULSE_DEFAULTS.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${PULSE_ENV:-$DIR/pulse-agent.env}"
: "${PULSE_URL:?set PULSE_URL}" "${PULSE_TOKEN:?set PULSE_TOKEN}"

# Each collector prints lines: "<name> <value> <low|null> <high|null>"
slug() { tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/_/g; s/^_+|_+$//g; s/_temp$//; s/^temp_//'; }

collect_ipmi() {
  command -v ipmitool >/dev/null 2>&1 || return 0
  # Columns: name | value | unit | status | LNR | LCR | LNC | UNC | UCR | UNR
  timeout 30 sudo -n /usr/bin/ipmitool sensor 2>/dev/null | awk -F'|' '
    function num(x) { return x ~ /^-?[0-9]+(\.[0-9]+)?$/ }
    { for (i = 1; i <= NF; i++) gsub(/^ +| +$/, "", $i) }
    $3 == "degrees C" && num($2) {
      lo = num($6) ? $6 : (num($5) ? $5 : "null")
      hi = num($9) ? $9 : (num($10) ? $10 : "null")
      print $1 "\t" $2 "\t" lo "\t" hi
    }' | while IFS=$'\t' read -r name value lo hi; do
      echo "$(slug <<<"$name") $value $lo $hi"
    done
}

collect_hwmon() {
  local h drv f base label n v lo hi t x
  local -A count=() seen=()
  for h in /sys/class/hwmon/hwmon*; do
    drv=$(cat "$h/name" 2>/dev/null) || continue
    count[$drv]=$(( ${count[$drv]:-0} + 1 ))
  done
  for h in /sys/class/hwmon/hwmon*; do
    drv=$(cat "$h/name" 2>/dev/null) || continue
    if (( count[$drv] > 1 )); then
      x=${seen[$drv]:-0}; seen[$drv]=$((x + 1)); drv="${drv}_$x"
    fi
    for f in "$h"/temp*_input; do
      [[ -r $f ]] || continue
      base=${f%_input}
      n=${base##*/temp}
      label=$(cat "${base}_label" 2>/dev/null || echo "temp$n")
      v=$(cat "$f" 2>/dev/null) || continue
      # Thresholds in millidegrees; drivers report junk like -273150 or 65261850 when unset.
      lo=null; hi=null
      for t in lcrit min; do
        x=$(cat "${base}_$t" 2>/dev/null || true)
        if [[ $x =~ ^-?[0-9]+$ ]] && ((x > -100000 && x < 250000)); then lo=$x; break; fi
      done
      for t in crit max; do
        x=$(cat "${base}_$t" 2>/dev/null || true)
        if [[ $x =~ ^-?[0-9]+$ ]] && ((x > -100000 && x < 250000)); then hi=$x; break; fi
      done
      awk -v name="$(slug <<<"${drv}_${label}")" -v v="$v" -v lo="$lo" -v hi="$hi" 'BEGIN {
        printf "%s %.1f %s %s\n", name, v / 1000, (lo == "null" ? "null" : sprintf("%.1f", lo / 1000)),
                                               (hi == "null" ? "null" : sprintf("%.1f", hi / 1000)) }'
    done
  done
}

collect_nvidia() {
  command -v nvidia-smi >/dev/null 2>&1 || return 0
  timeout 15 nvidia-smi --query-gpu=index,temperature.gpu,temperature.gpu.tlimit \
    --format=csv,noheader,nounits 2>/dev/null | awk -F', *' '
    $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ {
      hi = ($3 ~ /^-?[0-9]+$/) ? $2 + $3 : "null"
      print "nvidia_gpu" $1, $2, "null", hi
      if (!n++ || $2 + 0 > mx) mx = $2 + 0
      if (hi != "null" && (mh == "" || hi < mh)) mh = hi
    }
    END { if (n > 1) print "nvidia_gpu_max", mx, "null", (mh == "" ? "null" : mh) }' || true
}

# Merge, keep the first occurrence of a name, put the defaults first, build JSON (key order is kept).
payload=$({ collect_ipmi; collect_hwmon; collect_nvidia; } | awk -v defaults="${PULSE_DEFAULTS:-${PULSE_FIRST:-}}" '
  function num(x) { return x ~ /^-?[0-9]+(\.[0-9]+)?$/ }
  function add(i) {
    m = m (m ? "," : "") "\"" name[i] "\":" val[i]
    if (lo[i] != "null" || hi[i] != "null")
      l = l (l ? "," : "") "\"" name[i] "\":[" lo[i] "," hi[i] "]"
  }
  # No {m,n} regex intervals: mawk (Debian/Ubuntu default awk) does not support them.
  $1 ~ /^[a-z0-9][a-z0-9_-]*$/ && length($1) <= 32 && num($2) && !seen[$1]++ {
    n++; name[n] = $1; val[n] = $2; lo[n] = $3; hi[n] = $4; idx[$1] = n
  }
  END {
    if (!n) exit
    nd = split(defaults, want, /[ ,]+/)
    for (j = 1; j <= nd; j++) {
      i = idx[want[j]]
      if (i && !done[i]++) { add(i); d = d (d ? "," : "") "\"" name[i] "\"" }
    }
    for (i = 1; i <= n; i++) if (!done[i]) add(i)
    printf "{\"metrics\":{%s},\"limits\":{%s},\"defaults\":[%s]}", m, l, d
  }')

if [[ -z $payload ]]; then
  echo "pulse-agent: no temperature sensors found" >&2
  exit 1
fi

curl -fsS --max-time 15 --retry 2 --retry-delay 5 \
  -H "Authorization: Bearer $PULSE_TOKEN" \
  -H "Content-Type: application/json" \
  --data "$payload" \
  "${PULSE_URL%/}/ingest" >/dev/null
