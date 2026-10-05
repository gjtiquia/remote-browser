#!/usr/bin/env bash
set -euo pipefail
umask 077
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
trap 'echo "startup failed at line $LINENO; see runtime/chromium.log, then run ./stop.sh before retrying" >&2' ERR

export PATH="$HOME/.local/bin:$PATH"
missing=()
chromium_command=$(command -v chromium-browser || command -v chromium || true)
[[ -n "$chromium_command" ]] || missing+=("chromium or chromium-browser")
for dependency in node agent-browser tailscale jq curl sudo nohup fuser timeout; do
  command -v "$dependency" >/dev/null 2>&1 || missing+=("$dependency")
done
if (( ${#missing[@]} )); then
  echo "missing dependencies: ${missing[*]}" >&2
  exit 1
fi

# Keep the socket path short: the namespace used to push it past the limit.
export AGENT_BROWSER_SOCKET_DIR="$PWD/runtime/ab"
export AGENT_BROWSER_NAMESPACE=""
export AGENT_BROWSER_IDLE_TIMEOUT_MS=0
mkdir -p "$AGENT_BROWSER_SOCKET_DIR"
chmod 700 runtime "$AGENT_BROWSER_SOCKET_DIR"

# Start requires a clean slate; stop.sh deliberately clears these ports.
if fuser 9222/tcp 4848/tcp >/dev/null 2>&1; then
  echo "port 9222 or 4848 is occupied; run ./stop.sh before starting" >&2
  exit 1
fi

host=$(tailscale status --json | jq -er '
  select(.BackendState == "Running") | .Self.DNSName | rtrimstr(".") |
  select(endswith(".ts.net"))') || {
  echo "connect Tailscale and enable MagicDNS before starting" >&2
  exit 1
}
tailscale serve status --json | jq -e '
  .TCP["9223"] == null and .TCP["9222"] == null' >/dev/null || {
  echo "Tailscale Serve port 9223 or 9222 is already configured; run ./stop.sh first" >&2
  exit 1
}
echo "starting Chromium (log: runtime/chromium.log)..."
nohup "$chromium_command" --headless=new \
  --remote-debugging-port=9222 \
  --user-data-dir="$PWD/runtime/profile" \
  about:blank \
  >runtime/chromium.log 2>&1 &

ready=false
for ((i = 0; i < 30; i++)); do
  if curl --silent --fail --max-time 1 http://127.0.0.1:9222/json/version >/dev/null; then
    ready=true
    break
  fi
  sleep 1
done
if [[ "$ready" != true ]]; then
  echo "CDP port 9222 didn't become ready; see runtime/chromium.log, then run ./stop.sh" >&2
  exit 1
fi

echo "attaching agent-browser..."
agent-browser --session home connect 9222
agent-browser dashboard start --allowed-origins "https://$host:9223"

sudo tailscale serve --bg --https=9223 http://127.0.0.1:4848
sudo tailscale serve --bg --tcp=9222 tcp://127.0.0.1:9222

echo
echo "dashboard (HTTPS 9223): open the private tokenized URL printed above"
echo "select home and log in yourself; keep the dashboard token private"
echo
echo "send this CDP URL to the agent (TCP 9222; restrict access to the agent VPS):"
ip=$(tailscale ip -4)
curl --silent --fail http://127.0.0.1:9222/json/version | jq -er --arg ip "$ip" \
  '.webSocketDebuggerUrl | sub("://[^/]+"; "://" + $ip + ":9222")'
echo
echo "keep the laptop awake; run ./start.sh again after reboot"
echo "stop with ./stop.sh; tabs are cleared, logins stay in runtime/profile/"
echo "don't run start and stop simultaneously; use Tailscale Serve, never Funnel"
