#!/usr/bin/env bash
# pulse agent: collect every temperature the host exposes, plus CPU/RAM/GPU/disk usage, and push it.
# Run from cron every minute. Needs bash, curl, awk; optional sources are skipped if missing.
#
# Sources and metric names:
#   ipmitool sensor (BMC)   -> "system", "cpu", "gpu3", "dimma_f", ...   limits: LCR..UCR (fallback LNR..UNR)
#   /sys/class/hwmon        -> "<driver>_<label>", e.g. "k10temp_tctl", "nvme_composite"   limits: min/lcrit..crit/max
#                              drivers with several instances get a number: "coretemp_0_core_0", "coretemp_1_core_0"
#   nvidia-smi              -> "nvidia_gpu<N>"   limit: current + tlimit headroom (max operating temp)
#                              plus "nvidia_gpu_max" (hottest GPU) when there is more than one GPU
# (lm-sensors' `sensors` reads the same /sys/class/hwmon data, so it is not needed.)
#   usage (/proc, nvidia-smi) -> "cpu_pct", "mem_pct", "load_pct" (1-min load / cores), "gpu_pct", "vram_pct",
#                              "gpu<N>_pct", "gpu<N>_vram_pct" (multi-GPU), "disk_busy_pct", "disk_read_mbs",
#                              "disk_write_mbs". Names ending _pct are percent, _mbs MB/s, everything else °C.
#   info                    -> uptime, ncpu, mem_gb, load1/5/15 (shown as text, not graphed)
#
# ipmitool needs root; allow exactly this read-only command in sudoers:
#   <user> ALL=(root) NOPASSWD: /usr/bin/ipmitool sensor
# Config: pulse-agent.env next to this script.
#   PULSE_URL, PULSE_TOKEN   required
#   PULSE_DEFAULTS           optional comma list of metrics the page shows by default, e.g.
#                            "system,cpu,nvidia_gpu0". They are sent first, in this order. Without it the
#                            page shows only the first metric sent (order: ipmitool, hwmon, nvidia-smi).
#   PULSE_FIRST              older single-metric form of PULSE_DEFAULTS.
#   PULSE_STATE              state file for CPU/disk deltas (default .pulse-state next to this script).
# The usage aggregates (cpu_pct, mem_pct, ...) are always appended to the defaults.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${PULSE_ENV:-$DIR/pulse-agent.env}"
: "${PULSE_URL:?set PULSE_URL}" "${PULSE_TOKEN:?set PULSE_TOKEN}"
STATE=${PULSE_STATE:-$DIR/.pulse-state}

# Each collector prints lines: "<name> <value> <low|null> <high|null>"
slug() { tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/_/g; s/^_+|_+$//g; s/_temp$//; s/^temp_//'; }

collect_ipmi() {
  command -v ipmitool >/dev/null 2>&1 || return 0
  # Root (e.g. a systemd timer) needs no sudo; others use the narrow sudoers rule.
  local run=(sudo -n /usr/bin/ipmitool)
  (( EUID == 0 )) && run=(ipmitool)
  # Columns: name | value | unit | status | LNR | LCR | LNC | UNC | UCR | UNR
  timeout 30 "${run[@]}" sensor 2>/dev/null | awk -F'|' '
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
  timeout 15 nvidia-smi --query-gpu=index,temperature.gpu,temperature.gpu.tlimit,utilization.gpu,memory.used,memory.total \
    --format=csv,noheader,nounits 2>/dev/null | awk -F', *' '
    function int_(x) { return x ~ /^[0-9]+$/ }
    int_($1) && int_($2) {
      hi = ($3 ~ /^-?[0-9]+$/) ? $2 + $3 : "null"
      print "nvidia_gpu" $1, $2, "null", hi
      if (!n++ || $2 + 0 > mx) mx = $2 + 0
      if (hi != "null" && (mh == "" || hi < mh)) mh = hi
    }
    int_($1) { ng++; g[ng] = $1; u[ng] = $4; mu[ng] = $5; mt[ng] = $6 }
    END {
      if (n > 1) print "nvidia_gpu_max", mx, "null", (mh == "" ? "null" : mh)
      # Usage: per GPU only on multi-GPU hosts; gpu_pct / vram_pct are the whole-host figures.
      for (i = 1; i <= ng; i++) {
        if (int_(u[i])) { su += u[i]; nu++; if (ng > 1) print "gpu" g[i] "_pct", u[i], "null", "null" }
        if (int_(mu[i]) && int_(mt[i]) && mt[i] > 0) {
          smu += mu[i]; smt += mt[i]
          if (ng > 1) printf "gpu%s_vram_pct %.1f null null\n", g[i], 100 * mu[i] / mt[i]
        }
      }
      if (nu) printf "gpu_pct %.1f null null\n", su / nu
      if (smt) printf "vram_pct %.1f null null\n", 100 * smu / smt
    }' || true
}

# CPU busy %, RAM %, load % and disk I/O. CPU and disk are averaged since the previous run (state file),
# so the first run after install or after a long gap sends none of them.
collect_usage() {
  local up n l1 l5 l15 prev
  read -r up _ </proc/uptime
  read -r l1 l5 l15 _ </proc/loadavg
  n=$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo)
  awk -v l1="$l1" -v n="$n" 'BEGIN { if (n > 0) printf "load_pct %.1f null null\n", 100 * l1 / n }'
  awk '/^MemTotal:/ { t = $2 } /^MemAvailable:/ { a = $2 }
       END { if (t) printf "mem_pct %.1f null 90\n", 100 * (t - a) / t }' /proc/meminfo

  prev=$(cat "$STATE" 2>/dev/null || true)
  {
    echo "up $up"
    # /proc/stat cpu: user nice system idle iowait irq softirq steal (guest time is already in user)
    awk '$1 == "cpu" { print "cpu", $2 + $3 + $4 + $5 + $6 + $7 + $8 + $9, $5 + $6; exit }' /proc/stat
    # Whole physical disks only (they have a device link; loop, zram, dm and md do not).
    # /proc/diskstats: $3 name, $6 sectors read, $10 sectors written, $13 ms spent doing I/O
    awk 'FNR == NR { ok[$1]; next } ($3 in ok) { print "disk", $3, $6, $10, $13 }' \
      <(for b in /sys/block/*; do [[ -e $b/device ]] && echo "${b##*/}"; done) /proc/diskstats
  } >"$STATE.tmp" 2>/dev/null && mv -f "$STATE.tmp" "$STATE" || return 0

  { sed 's/^/P /' <<<"$prev"; sed 's/^/C /' "$STATE"; } | awk '
    $2 == "up"   { up[$1] = $3 }
    $2 == "cpu"  { tot[$1] = $3; idle[$1] = $4 }
    $2 == "disk" { r[$1, $3] = $4; w[$1, $3] = $5; t[$1, $3] = $6; if ($1 == "C") d[$3] }
    END {
      dt = up["C"] - up["P"]
      if (up["P"] == "" || dt <= 0 || dt > 900) exit     # first run, reboot, or stale state
      if (tot["C"] > tot["P"])
        printf "cpu_pct %.1f null null\n", 100 * (1 - (idle["C"] - idle["P"]) / (tot["C"] - tot["P"]))
      for (k in d) {
        if (!(("P", k) in r) || r["C", k] < r["P", k] || w["C", k] < w["P", k] || t["C", k] < t["P", k]) continue
        nd++; rs += r["C", k] - r["P", k]; ws += w["C", k] - w["P", k]
        b = (t["C", k] - t["P", k]) / (dt * 10); if (b > mb) mb = b
      }
      if (nd) {
        printf "disk_read_mbs %.2f null null\n", rs * 512 / 1e6 / dt
        printf "disk_write_mbs %.2f null null\n", ws * 512 / 1e6 / dt
        printf "disk_busy_pct %.1f null null\n", (mb > 100 ? 100 : mb)
      }
    }'
}

# Facts shown as text on the page, not graphed.
host_info() {
  local up n l1 l5 l15
  read -r up _ </proc/uptime
  read -r l1 l5 l15 _ </proc/loadavg
  n=$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo)
  awk -v up="$up" -v n="$n" -v l1="$l1" -v l5="$l5" -v l15="$l15" '/^MemTotal:/ { t = $2 }
    END { printf "\"uptime\":%d,\"ncpu\":%d,\"mem_gb\":%.1f,\"load1\":%s,\"load5\":%s,\"load15\":%s",
                 up, n, t / 1048576, l1, l5, l15 }' /proc/meminfo
}

# Merge, keep the first occurrence of a name, put the defaults first, build JSON (key order is kept).
# Usage figures the page always shows by default, after the temperature defaults.
USAGE_DEFAULTS="cpu_pct mem_pct load_pct gpu_pct vram_pct disk_busy_pct disk_read_mbs disk_write_mbs"
payload=$({ collect_ipmi; collect_hwmon; collect_nvidia; collect_usage; } | awk \
  -v defaults="${PULSE_DEFAULTS:-${PULSE_FIRST:-}}" -v usage="$USAGE_DEFAULTS" -v info="$(host_info)" '
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
    if (!idx[want[1]] && nd <= 1) { nd = 1; want[1] = name[1] }   # no PULSE_DEFAULTS: first metric sent
    nu = split(usage, extra, / /)
    for (j = 1; j <= nu; j++) want[++nd] = extra[j]
    for (j = 1; j <= nd; j++) {
      i = idx[want[j]]
      if (i && !done[i]++) { add(i); d = d (d ? "," : "") "\"" name[i] "\"" }
    }
    for (i = 1; i <= n; i++) if (!done[i]) add(i)
    printf "{\"metrics\":{%s},\"limits\":{%s},\"defaults\":[%s],\"info\":{%s}}", m, l, d, info
  }')

if [[ -z $payload ]]; then
  echo "pulse-agent: nothing to send" >&2
  exit 1
fi

curl -fsS --max-time 15 --retry 2 --retry-delay 5 \
  -H "Authorization: Bearer $PULSE_TOKEN" \
  -H "Content-Type: application/json" \
  --data "$payload" \
  "${PULSE_URL%/}/ingest" >/dev/null
