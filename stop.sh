#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"

export PATH="$HOME/.local/bin:$PATH"
export AGENT_BROWSER_SOCKET_DIR="$PWD/runtime/agent-browser"
export AGENT_BROWSER_NAMESPACE=remote-browser
export AGENT_BROWSER_IDLE_TIMEOUT_MS=0

if [[ ! -f runtime/chromium.pid ]]; then
  echo "already stopped"
  exit 0
fi

# Remove only the two Serve routes created by start.sh; never reset all routes.
if [[ -f runtime/serve-9222 ]]; then
  sudo tailscale serve --tcp=9222 off
  rm runtime/serve-9222
fi
# Include 443 to clean up a browser started with the previous script version.
for port in 9223 443; do
  if [[ -f runtime/serve-$port ]]; then
    sudo tailscale serve --https="$port" off
    rm "runtime/serve-$port"
  fi
done

# A crashed/partially started daemon mustn't prevent Chromium cleanup.
agent-browser dashboard stop || echo "dashboard was unavailable" >&2
agent-browser --session home close || echo "browser session was unavailable" >&2

# Kill only our tracked Chromium, never other browser processes.
pid=$(<runtime/chromium.pid)
if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null &&
  grep -zFxq -- "--user-data-dir=$PWD/runtime/profile" "/proc/$pid/cmdline"; then
  kill "$pid"
  for ((i = 0; i < 30; i++)); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 1
  done
  if kill -0 "$pid" 2>/dev/null; then
    echo "Chromium hasn't stopped yet; try ./stop.sh again" >&2
    exit 1
  fi
fi
rm runtime/chromium.pid

echo "stopped (profile and logins kept in runtime/profile/)"
