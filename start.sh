#!/usr/bin/env bash
set -euo pipefail
umask 077
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"

export PATH="$HOME/.local/bin:$PATH"
export AGENT_BROWSER_SOCKET_DIR="$PWD/runtime/agent-browser"
export AGENT_BROWSER_NAMESPACE=remote-browser
export AGENT_BROWSER_IDLE_TIMEOUT_MS=0
mkdir -p "$AGENT_BROWSER_SOCKET_DIR"
chmod 700 runtime "$AGENT_BROWSER_SOCKET_DIR"

# Don't launch Chromium twice against the same profile.
if [[ -f runtime/chromium.pid ]]; then
  pid=$(<runtime/chromium.pid)
  if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null &&
    grep -zFxq -- "--user-data-dir=$PWD/runtime/profile" "/proc/$pid/cmdline"; then
    echo "already running (run ./stop.sh first if setup was interrupted)"
    exit 0
  fi
  echo "previous process stopped; run ./stop.sh to clean up before starting"
  exit 1
fi

host=$(tailscale status --json | jq -er '
  select(.BackendState == "Running") | .Self.DNSName | rtrimstr(".") |
  select(endswith(".ts.net"))') || {
  echo "connect Tailscale and enable MagicDNS before starting" >&2
  exit 1
}

# These two ports belong to this project. Don't overwrite existing Serve routes.
tailscale serve status --json | jq -e '
  .TCP["9223"] == null and .TCP["9222"] == null' >/dev/null || {
  echo "Tailscale Serve port 9223 or 9222 is already in use" >&2
  exit 1
}

if curl --silent --fail --max-time 1 http://127.0.0.1:9222/json/version >/dev/null; then
  echo "CDP port 9222 is already in use by another browser" >&2
  exit 1
fi

nohup chromium --headless=new \
  --remote-debugging-port=9222 \
  --user-data-dir="$PWD/runtime/profile" \
  >runtime/chromium.log 2>&1 &
echo "$!" >runtime/chromium.pid

# Give Chromium a moment to expose CDP before attaching.
for ((i = 0; i < 30; i++)); do
  curl --silent --fail --max-time 1 http://127.0.0.1:9222/json/version >/dev/null && break
  sleep 1
done
curl --silent --fail --max-time 1 http://127.0.0.1:9222/json/version >/dev/null
pid=$(<runtime/chromium.pid)
grep -zFxq -- "--user-data-dir=$PWD/runtime/profile" "/proc/$pid/cmdline"

agent-browser --session home connect 9222
agent-browser --session home open https://www.reddit.com
agent-browser dashboard start --allowed-origins "https://$host:9223"

# Mark routes before applying them so stop.sh can clean up a partial startup.
touch runtime/serve-9223
sudo tailscale serve --bg --https=9223 http://127.0.0.1:4848
touch runtime/serve-9222
sudo tailscale serve --bg --tcp=9222 tcp://127.0.0.1:9222

echo "dashboard: use the private tokenized URL printed above"
echo "agent CDP:"
ip=$(tailscale ip -4)
curl --silent --fail http://127.0.0.1:9222/json/version | jq -er --arg ip "$ip" \
  '.webSocketDebuggerUrl | sub("://[^/]+"; "://" + $ip + ":9222")'
