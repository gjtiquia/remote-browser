#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
export PATH="$HOME/.local/bin:$PATH"
export AGENT_BROWSER_SOCKET_DIR="$PWD/runtime/ab"
export AGENT_BROWSER_NAMESPACE=""
export AGENT_BROWSER_IDLE_TIMEOUT_MS=0

# Find the actual browser even if the launcher exited or its PID file is gone.
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
if (( ${#pids[@]} == 0 )) &&
  [[ ! -f runtime/started && ! -f runtime/chromium.pid &&
     ! -f runtime/agent-attached && ! -f runtime/dashboard-started &&
     ! -f runtime/serve-9222 && ! -f runtime/serve-9223 && ! -f runtime/serve-443 ]]; then
  echo "already stopped"
  exit 0
fi

echo "stopping this project's browser and routes..."
failed=0
# Never reset all Serve routes. Also support markers from the old port-443 script.
for port in 9222 9223 443; do
  if [[ -f runtime/serve-$port ]]; then
    if [[ "$port" == 9222 ]]; then option=--tcp=9222; else option=--https="$port"; fi
    if sudo tailscale serve "$option" off; then
      rm "runtime/serve-$port"
    else
      echo "couldn't remove Tailscale port $port; browser cleanup will still run" >&2
      failed=1
    fi
  fi
done

if [[ -f runtime/dashboard-started ]]; then
  if agent-browser dashboard stop; then rm runtime/dashboard-started;
  else failed=1; fi
fi
if [[ -f runtime/agent-attached ]]; then
  if agent-browser --session home close; then rm runtime/agent-attached;
  else failed=1; fi
fi

# Recheck each PID's exact profile before signalling it; never pkill all Chromium.
mapfile -t pids < <(browser_pids)
for pid in "${pids[@]}"; do
  if grep -zFxq -- "--user-data-dir=$PWD/runtime/profile" "/proc/$pid/cmdline" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
  fi
done
for ((i = 0; i < 20; i++)); do
  mapfile -t pids < <(browser_pids)
  (( ${#pids[@]} == 0 )) && break
  sleep 0.5
done
if (( ${#pids[@]} )); then
  echo "browser didn't exit gracefully; force-stopping only this profile" >&2
  for pid in "${pids[@]}"; do
    if grep -zFxq -- "--user-data-dir=$PWD/runtime/profile" "/proc/$pid/cmdline" 2>/dev/null; then
      kill -KILL "$pid" 2>/dev/null || true
    fi
  done
  sleep 0.5
fi
mapfile -t pids < <(browser_pids)
if (( ${#pids[@]} )); then
  echo "browser processes still running: ${pids[*]}" >&2
  failed=1
fi
if (( failed )); then
  echo "cleanup incomplete; fix the errors above and run ./stop.sh again" >&2
  exit 1
fi
rm -f runtime/chromium.pid runtime/started
echo "stopped (profile and logins kept in runtime/profile/)"
