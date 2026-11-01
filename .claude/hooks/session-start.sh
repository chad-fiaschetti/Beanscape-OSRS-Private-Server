#!/bin/bash
# Joins this cloud session to the tailnet and sets up `ssh <host>` for every Linux peer.
# Needs TS_AUTHKEY and BEAN_SSH_KEY in the cloud environment's variables.
# Never fails the session: problems are logged to /tmp/session-start-tailscale.log.
set -uo pipefail

if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

log=/tmp/session-start-tailscale.log
sock=/var/run/tailscale/tailscaled.sock
exec 3>>"$log"
note() { echo "[session-start] $*" | tee /dev/fd/3 >&2; }

if [ -z "${TS_AUTHKEY:-}" ] || [ -z "${BEAN_SSH_KEY:-}" ]; then
  note "TS_AUTHKEY or BEAN_SSH_KEY not set; skipping tailnet setup"
  exit 0
fi

install -d -m 700 ~/.ssh
printf '%s\n' "$BEAN_SSH_KEY" > ~/.ssh/id_bean
chmod 600 ~/.ssh/id_bean

# tailscaled in userspace mode (works in the gVisor sandbox)
if ! tailscale --socket="$sock" status >/dev/null 2>&1; then
  if ! pgrep -x tailscaled >/dev/null; then
    install -d /var/run/tailscale
    nohup tailscaled --tun=userspace-networking --state=mem: --socket="$sock" \
      >/tmp/tailscaled.log 2>&1 &
    for _ in $(seq 1 20); do [ -S "$sock" ] && break; sleep 0.5; done
  fi
  if ! timeout 60 tailscale --socket="$sock" up --authkey="$TS_AUTHKEY" \
      --hostname="claude-cloud-$(hostname | cut -c1-12)" --accept-dns=false >&3 2>&1; then
    note "tailscale up failed; see $log and /tmp/tailscaled.log"
    exit 0
  fi
fi

# SSH config: every Linux tailnet peer by short name, plus any 100.x address
# (rewritten every run so new machines and env changes take effect)
peers=$(tailscale --socket="$sock" status --json 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
print(" ".join(sorted(p["DNSName"].split(".")[0].lower() for p in (d.get("Peer") or {}).values()
                      if p.get("OS") == "linux" and "tag:cloud" not in (p.get("Tags") or []))))
' 2>/dev/null)
touch ~/.ssh/config && chmod 600 ~/.ssh/config
sed -i '/^# >>> beanlab-tailnet >>>$/,/^# <<< beanlab-tailnet <<<$/d' ~/.ssh/config
cat >> ~/.ssh/config <<SSHCFG
# >>> beanlab-tailnet >>>
Host ${peers:-gitea} *.tail5475a4.ts.net 100.*
  User root
  IdentityFile ~/.ssh/id_bean
  IdentitiesOnly yes
  StrictHostKeyChecking accept-new
  ConnectTimeout 15
  ProxyCommand tailscale --socket=$sock nc %h %p
# <<< beanlab-tailnet <<<
SSHCFG

note "tailnet up as $(tailscale --socket="$sock" ip -4 2>/dev/null | head -1); ssh hosts: ${peers:-gitea}"
exit 0
