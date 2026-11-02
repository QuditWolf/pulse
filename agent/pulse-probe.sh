#!/usr/bin/env bash
# pulse probe: read-only. Lists temperature sources + what the agent needs. Paste output back.
echo "== host"; uname -a; cat /etc/os-release 2>/dev/null | grep -E '^(NAME|BUILD_ID)='; id
echo "== tools"; for c in bash curl awk gawk mawk ipmitool nvidia-smi sensors sudo crontab systemctl docker git; do
  printf '%-11s %s\n' "$c" "$(command -v $c || echo -)"; done
echo "== hwmon (millidegC: input lo/min/lcrit hi/max/crit)"
for h in /sys/class/hwmon/hwmon*; do
  echo "-- $h name=$(cat $h/name 2>/dev/null) dev=$(readlink -f $h/device 2>/dev/null)"
  for f in "$h"/temp*_input; do [[ -r $f ]] || continue; b=${f%_input}
    printf '  %-8s label=%-16s in=%-7s' "${b##*/}" "$(cat ${b}_label 2>/dev/null || echo -)" "$(cat $f 2>/dev/null || echo ERR)"
    for t in min lcrit max crit; do printf ' %s=%s' $t "$(cat ${b}_$t 2>/dev/null || echo -)"; done; echo
  done
done
echo "== thermal_zone"; for z in /sys/class/thermal/thermal_zone*; do
  [[ -r $z/temp ]] && echo "$z type=$(cat $z/type) temp=$(cat $z/temp)"; done
echo "== drivetemp/nvme/modules"; lsmod 2>/dev/null | grep -E '^(drivetemp|k10temp|coretemp|nct|it87|nvme|amdgpu|nouveau|nvidia) ' || echo none
lsblk -d -o NAME,MODEL,TRAN 2>/dev/null
echo "== ipmitool"; command -v ipmitool >/dev/null && timeout 30 ipmitool sensor 2>&1 | grep -i 'degrees' | head -40 || echo "no ipmitool"
ls /dev/ipmi* 2>/dev/null || echo "no /dev/ipmi*"
echo "== nvidia-smi"; command -v nvidia-smi >/dev/null && timeout 15 nvidia-smi --query-gpu=index,name,temperature.gpu,temperature.gpu.tlimit --format=csv 2>&1 || echo "no nvidia-smi"
echo "== sensors"; command -v sensors >/dev/null && sensors 2>&1 | head -60 || echo "no lm_sensors"
echo "== scheduler"; systemctl is-active cronie 2>/dev/null; systemctl list-timers --no-pager 2>/dev/null | tail -n +1 | head -15
echo "== pulse server"; docker ps --filter name=pulse --format '{{.Names}} {{.Status}} {{.Ports}}' 2>&1
for d in /root/pulse/server /opt/pulse/server $(find / -maxdepth 4 -type d -path '*pulse/server' 2>/dev/null | head -3); do
  [[ -f $d/.env ]] && { echo "env: $d/.env"; grep -E '^(BIND_ADDR|PULSE_OFFLINE_AFTER)=' $d/.env; grep -oE '^PULSE_TOKENS=' $d/.env >/dev/null && echo "hosts: $(sed -n 's/^PULSE_TOKENS=//p' $d/.env | tr ',' '\n' | cut -d= -f1 | xargs)"; break; }
done
ip -br -4 addr 2>/dev/null
