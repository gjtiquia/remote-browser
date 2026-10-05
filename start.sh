#!/usr/bin/env bash
set -euo pipefail
umask 077
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
trap 'echo "startup failed at line $LINENO; see runtime/chromium.log, then run ./stop.sh before retrying" >&2' ERR

export PATH="$HOME/.local/bin:$PATH"
missing=()
chromium_command=$(command -v chromium-browser || command -v chromium || true)
[[ -n "$chromium_command" ]] || missing+=("chromium or chromium-browser")
for dependency in node agent-browser tailscale jq curl sudo nohup grep; do
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

# Fedora's launcher can exit while the actual browser keeps running.
# Match the exact profile argument, not the launcher's PID or a broad process name.
browser_pids() {
  local file pid
  for file in /proc/[0-9]*/cmdline; do
    if grep -zFxq -- "--user-data-dir=$PWD/runtime/profile" "$file" 2>/dev/null; then
      pid=${file#/proc/}
      echo "${pid%/cmdline}"
    fi
  done
}
mapfile -t pids < <(browser_pids)
if (( ${#pids[@]} )); then
  if [[ -f runtime/started ]]; then
    echo "already running"
    exit 0
  fi
  echo "browser left over from an interrupted startup; run ./stop.sh first" >&2
  exit 1
fi
if [[ -f runtime/started || -f runtime/agent-attached || -f runtime/dashboard-started ||
      -f runtime/serve-9222 || -f runtime/serve-9223 || -f runtime/serve-443 ]]; then
  echo "previous setup needs cleanup; run ./stop.sh first" >&2
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
  echo "Tailscale Serve port 9223 or 9222 is already in use" >&2
  exit 1
}
if curl --silent --fail --max-time 1 http://127.0.0.1:9222/json/version >/dev/null; then
  echo "CDP port 9222 is occupied by a browser outside this project's profile; refusing to attach" >&2
  exit 1
fi

echo "starting Chromium (log: runtime/chromium.log)..."
nohup "$chromium_command" --headless=new \
  --remote-debugging-port=9222 \
  --user-data-dir="$PWD/runtime/profile" \
  >runtime/chromium.log 2>&1 &

ready=false
for ((i = 0; i < 30; i++)); do
  if curl --silent --fail --max-time 1 http://127.0.0.1:9222/json/version >/dev/null; then
    ready=true
    break
  fi
  sleep 1
done
mapfile -t pids < <(browser_pids)
if [[ "$ready" != true ]] || (( ${#pids[@]} == 0 )); then
  echo "Chromium didn't start with this project's profile; see runtime/chromium.log" >&2
  exit 1
fi

echo "attaching agent-browser..."
touch runtime/agent-attached
agent-browser --session home connect 9222
agent-browser --session home open https://www.reddit.com
touch runtime/dashboard-started
agent-browser dashboard start --allowed-origins "https://$host:9223"

# Mark routes before applying them so stop.sh can clean up a partial startup.
touch runtime/serve-9223
sudo tailscale serve --bg --https=9223 http://127.0.0.1:4848
touch runtime/serve-9222
sudo tailscale serve --bg --tcp=9222 tcp://127.0.0.1:9222

echo
echo "dashboard (HTTPS 9223): open the private tokenized URL printed above"
echo "select home and log in yourself; keep the dashboard token private"
echo
echo "send this CDP URL to the agent (TCP 9222; restrict access to the agent VPS):"
ip=$(tailscale ip -4)
curl --silent --fail http://127.0.0.1:9222/json/version | jq -er --arg ip "$ip" \
  '.webSocketDebuggerUrl | sub("://[^/]+"; "://" + $ip + ":9222")'
touch runtime/started
echo
echo "keep the laptop awake; run ./start.sh again after reboot"
echo "stop with ./stop.sh; logins stay in runtime/profile/"
echo "don't run start and stop simultaneously; use Tailscale Serve, never Funnel"
