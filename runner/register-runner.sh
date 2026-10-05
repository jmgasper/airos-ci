#!/usr/bin/env bash
# register-runner.sh REPO [HOST]
#
# Register a GitHub Actions self-hosted runner for jmgasper/REPO on the build
# server (default airos-build.local) and start it as a systemd service.
# Run on a machine where `gh` is logged in as the repository owner and which
# can ssh to HOST as an account that may sudo.
#
# Each repository gets its own runner instance (GitHub user accounts have no
# account-wide runners): /data1/runner/REPO, running as the unprivileged user
# ghrunner (no sudo, no docker) with the labels self-hosted, airos-build.
#
# Also sets the repository so that workflow runs from outside contributors'
# pull requests always wait for approval: the runner is a real machine.
set -euo pipefail

REPO=${1:?usage: register-runner.sh REPO [HOST]}
HOST=${2:-airos-build.local}
OWNER=${GITHUB_OWNER:-jmgasper}
RUNNER_VERSION=${RUNNER_VERSION:-$(gh api repos/actions/runner/releases/latest --jq .tag_name | sed 's/^v//')}
SSH=(ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new)

token=$(gh api -X POST "repos/$OWNER/$REPO/actions/runners/registration-token" --jq .token)
gh api -X PUT "repos/$OWNER/$REPO/actions/permissions/fork-pr-contributor-approval" \
	-f approval_policy=all_external_contributors >/dev/null 2>&1 \
	|| echo "warning: could not set the fork pull request approval policy" >&2

name="airos-build-${REPO,,}"
dir=/data1/runner/$REPO
password=${SUDO_PASSWORD:-}
if [[ -z $password ]]; then
	read -rsp "sudo password on $HOST: " password
	echo
fi
"${SSH[@]}" "$HOST" bash -s -- "$REPO" "$OWNER" "$token" "$name" "$dir" "$RUNNER_VERSION" "$password" <<'REMOTE'
set -euo pipefail
repo=$1 owner=$2 token=$3 name=$4 dir=$5 version=$6 password=$7
cache=/data2/airos/cache/actions-runner-linux-x64-$version.tar.gz
as_runner() { echo "$password" | sudo -S -p '' -u ghrunner -H bash -c "umask 002; $1"; }
if [[ ! -f $cache ]]; then
	curl -fsSL -o "$cache.part" \
		"https://github.com/actions/runner/releases/download/v$version/actions-runner-linux-x64-$version.tar.gz"
	mv "$cache.part" "$cache"
	chmod 644 "$cache"
fi
if [[ -f $dir/.runner ]]; then
	echo "$repo: runner already configured in $dir"
else
	as_runner "mkdir -p '$dir' /data2/airos/runner-work && tar xzf '$cache' -C '$dir'"
	as_runner "cd '$dir' && ./config.sh --unattended --replace --url 'https://github.com/$owner/$repo' \
		--token '$token' --name '$name' --labels airos-build \
		--work '/data2/airos/runner-work/$repo'"
	# The runner's jobs need the air/OS tree's group access (umask 002).
	as_runner "cd '$dir' && printf 'LANG=C.UTF-8\n' >> .env"
	echo "$password" | sudo -S -p '' bash -c "cd '$dir' && ./svc.sh install ghrunner >/dev/null"
	unit=actions.runner.$owner-$repo.$name.service
	# Files the jobs create stay writable for the airos group (umask 002).
	echo "$password" | sudo -S -p '' bash -c "mkdir -p /etc/systemd/system/$unit.d \
		&& printf '[Service]\nUMask=0002\n' > /etc/systemd/system/$unit.d/umask.conf \
		&& systemctl daemon-reload && systemctl start $unit"
fi
systemctl is-active "actions.runner.$owner-$repo.$name.service"
REMOTE
gh api "repos/$OWNER/$REPO/actions/runners" --jq '.runners[] | "\(.name)\t\(.status)\t\([.labels[].name] | join(","))"'
