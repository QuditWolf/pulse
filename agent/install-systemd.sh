#!/usr/bin/env bash
# Install or update the pulse agent as a root systemd timer (for hosts without cron, e.g. Arch).
#
# First install:
#   curl -fsSL https://raw.githubusercontent.com/QuditWolf/pulse/main/agent/install-systemd.sh \
#     | PULSE_URL=<pulse-url> PULSE_TOKEN=<token> PULSE_DEFAULTS=coretemp_package_id_0 bash
# Update agent script only (keeps the existing env file):
#   curl -fsSL https://raw.githubusercontent.com/QuditWolf/pulse/main/agent/install-systemd.sh | bash
set -euo pipefail

RAW=${PULSE_RAW:-https://raw.githubusercontent.com/QuditWolf/pulse/main}
DIR=/opt/pulse-agent
(( EUID == 0 )) || { echo "run as root" >&2; exit 1; }

install -d -m 755 "$DIR"
curl -fsSL "$RAW/agent/pulse-agent.sh" -o "$DIR/pulse-agent.sh.new"
bash -n "$DIR/pulse-agent.sh.new"
install -m 755 "$DIR/pulse-agent.sh.new" "$DIR/pulse-agent.sh" && rm -f "$DIR/pulse-agent.sh.new"

if [[ -n ${PULSE_TOKEN:-} ]]; then
  : "${PULSE_URL:?set PULSE_URL}"
  umask 077
  {
    echo "PULSE_URL=$PULSE_URL"
    echo "PULSE_TOKEN=$PULSE_TOKEN"
    [[ -n ${PULSE_DEFAULTS:-} ]] && echo "PULSE_DEFAULTS=$PULSE_DEFAULTS"
  } > "$DIR/pulse-agent.env"
  chmod 600 "$DIR/pulse-agent.env"
elif [[ ! -f $DIR/pulse-agent.env ]]; then
  echo "no $DIR/pulse-agent.env yet: pass PULSE_URL and PULSE_TOKEN" >&2; exit 1
fi

cat > /etc/systemd/system/pulse-agent.service <<EOF
[Unit]
Description=pulse agent: push temperatures
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=$DIR/pulse-agent.sh
Nice=10
EOF

cat > /etc/systemd/system/pulse-agent.timer <<'EOF'
[Unit]
Description=pulse agent every minute

[Timer]
OnCalendar=minutely
AccuracySec=5s

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now pulse-agent.timer
systemctl start pulse-agent.service && echo "pulse-agent: first push ok"
systemctl list-timers pulse-agent.timer --no-pager
