#!/usr/bin/env bash
# dashboard/install.sh: set up the build dashboard on the build server. Run as
# root (sudo dashboard/install.sh); again to update it.
#
#   - a clone of jmgasper/airos-ci, owned by the runner user, in
#     /data1/airos/dashboard/airos-ci: the dashboard runs from it, and the
#     builds it starts run its scripts (it is reset to origin/main for each)
#   - the systemd service airos-dashboard (127.0.0.1:8090, as the runner user;
#     KillMode=process, so restarting it leaves running builds alone)
#   - nginx on port 80 (images/serve-artifacts.sh): the dashboard at /, the
#     image files at /images/
set -euo pipefail
[[ $(id -u) == 0 ]] || { echo "run as root" >&2; exit 1; }
USER_NAME=${RUNNER_USER:-ghrunner}
GROUP_NAME=$(id -gn "$USER_NAME")
DIR=/data1/airos/dashboard
CHECKOUT=$DIR/airos-ci
REPO=${AIROS_CI_REPO:-https://github.com/jmgasper/airos-ci.git}

install -d -o "$USER_NAME" -g "$GROUP_NAME" -m 2775 "$DIR" /data2/airos/builds
if [[ ! -d $CHECKOUT/.git ]]; then
	sudo -u "$USER_NAME" git clone -q "$REPO" "$CHECKOUT"
fi
sudo -u "$USER_NAME" git -C "$CHECKOUT" fetch -q origin main
sudo -u "$USER_NAME" git -C "$CHECKOUT" reset -q --hard origin/main

cat > /etc/systemd/system/airos-dashboard.service <<EOF
[Unit]
Description=air/OS build dashboard
After=network-online.target
Wants=network-online.target

[Service]
User=$USER_NAME
Group=$GROUP_NAME
UMask=0002
WorkingDirectory=$DIR
Environment=DASHBOARD_CHECKOUT=$CHECKOUT
ExecStart=/usr/bin/python3 $CHECKOUT/dashboard/server.py
Restart=always
RestartSec=3
# Builds started from the page run in sessions of their own; a restart of the
# dashboard must not end them.
KillMode=process

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable -q airos-dashboard
systemctl restart airos-dashboard

# nginx: the dashboard and the image files on port 80
"$CHECKOUT/images/serve-artifacts.sh"
sleep 2
curl -fsS -o /dev/null http://127.0.0.1/api/status && echo "dashboard: http://$(hostname -I | awk '{print $1}')/"
