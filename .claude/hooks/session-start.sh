#!/bin/bash
# Joins this Claude Code cloud session to your tailnet and sets up `ssh <host>`
# for every machine on it. Set these in the cloud environment's variables:
#   TS_AUTHKEY         required. Ephemeral, reusable, pre-approved auth key tagged tag:cloud
#                      (or an OAuth client secret, tskey-client-..., together with TS_TAGS)
#   CLOUD_SSH_KEY      OpenSSH private key, whole file. CLOUD_SSH_KEY_B64 (base64 of the
#                      file) also works; BEAN_SSH_KEY is accepted as an older name.
#   SSH_DEFAULT_USER   optional, default root
#   TS_TAGS            optional, e.g. tag:cloud (required with an OAuth client secret)
# Never fails the session: problems are logged to /tmp/session-start-tailscale.log.
set -uo pipefail

if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

log=/tmp/session-start-tailscale.log
sock=/var/run/tailscale/tailscaled.sock
socks5=localhost:1055
httpproxy=localhost:1056
exec 3>>"$log"
note() { echo "[session-start] $*" | tee /dev/fd/3 >&2; }
ts() { tailscale --socket="$sock" "$@"; }

if [ -z "${TS_AUTHKEY:-}" ]; then
  note "TS_AUTHKEY not set; skipping tailnet setup"
  exit 0
fi
if ! command -v tailscaled >/dev/null; then
  note "tailscale is not installed; add it to the environment's setup script"
  exit 0
fi

key="${CLOUD_SSH_KEY:-${BEAN_SSH_KEY:-}}"
if [ -z "$key" ] && [ -n "${CLOUD_SSH_KEY_B64:-}" ]; then
  key=$(printf '%s' "$CLOUD_SSH_KEY_B64" | base64 -d 2>/dev/null)
fi
install -d -m 700 ~/.ssh
if [ -n "$key" ]; then
  printf '%s\n' "$key" > ~/.ssh/id_tailnet
  chmod 600 ~/.ssh/id_tailnet
else
  note "no CLOUD_SSH_KEY set; only hosts using Tailscale SSH will accept logins"
fi

# tailscaled in userspace mode (works in the gVisor sandbox). Userspace mode has no
# network interface, so other tools reach the tailnet through its SOCKS5/HTTP proxy.
if ! ts status >/dev/null 2>&1; then
  if ! pgrep -x tailscaled >/dev/null; then
    install -d /var/run/tailscale
    nohup tailscaled --tun=userspace-networking --state=mem: --socket="$sock" \
      --socks5-server="$socks5" --outbound-http-proxy-listen="$httpproxy" \
      >/tmp/tailscaled.log 2>&1 &
    for _ in $(seq 1 20); do [ -S "$sock" ] && break; sleep 0.5; done
  fi
  up_args=(up --authkey="$TS_AUTHKEY" --hostname="claude-cloud-$(hostname | cut -c1-12)" --accept-dns=false)
  if [ -n "${TS_TAGS:-}" ]; then
    up_args+=(--advertise-tags="$TS_TAGS")
  fi
  if ! timeout 60 tailscale --socket="$sock" "${up_args[@]}" >&3 2>&1; then
    note "tailscale up failed; see $log and /tmp/tailscaled.log"
    exit 0
  fi
fi

# SSH config: every tailnet peer that can run SSH, by MagicDNS short name, plus full
# MagicDNS names and 100.x addresses (rewritten every run so new machines show up)
read -r suffix peers < <(ts status --json 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
suffix = (d.get("MagicDNSSuffix") or "ts.net").strip(".")
names = sorted(
    p["DNSName"].split(".")[0].lower()
    for p in (d.get("Peer") or {}).values()
    if p.get("OS") not in ("iOS", "android", "tvOS") and "tag:cloud" not in (p.get("Tags") or [])
)
print(suffix, " ".join(names))
' 2>/dev/null)
suffix=${suffix:-ts.net}
touch ~/.ssh/config && chmod 600 ~/.ssh/config
sed -i '/^# >>> claude-tailnet >>>$/,/^# <<< claude-tailnet <<<$/d; /^# >>> beanlab-tailnet >>>$/,/^# <<< beanlab-tailnet <<<$/d' ~/.ssh/config
cat >> ~/.ssh/config <<SSHCFG
# >>> claude-tailnet >>>
Host ${peers} *.${suffix} 100.*
  User ${SSH_DEFAULT_USER:-root}
  IdentityFile ~/.ssh/id_tailnet
  IdentitiesOnly yes
  StrictHostKeyChecking accept-new
  ConnectTimeout 15
  ProxyCommand tailscale --socket=$sock nc %h %p
# <<< claude-tailnet <<<
SSHCFG

# Proxy addresses for API calls to tailnet services, e.g.
#   curl --proxy "\$TAILNET_SOCKS5" https://grafana.<tailnet>.ts.net/api/health
if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  {
    echo "export TAILNET_SOCKS5=socks5h://$socks5"
    echo "export TAILNET_HTTP_PROXY=http://$httpproxy"
    echo "export TAILNET_SUFFIX=$suffix"
  } >> "$CLAUDE_ENV_FILE"
fi

note "tailnet up as $(ts ip -4 2>/dev/null | head -1) ($suffix); ssh hosts: ${peers:-none}"
exit 0
