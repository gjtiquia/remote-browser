#!/usr/bin/env bash
set -euo pipefail
umask 077
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
export PATH="$HOME/.local/bin:$PATH"
export AGENT_BROWSER_SOCKET_DIR="$PWD/runtime/ab"
export AGENT_BROWSER_NAMESPACE=""
export AGENT_BROWSER_IDLE_TIMEOUT_MS=0

for dependency in fuser tailscale jq sudo timeout; do
  command -v "$dependency" >/dev/null 2>&1 || {
    echo "missing dependency: $dependency (Fedora: fuser is in psmisc)" >&2
    exit 1
  }
done

echo "clearing local ports 9222 (browser) and 4848 (dashboard)..."
# Give agent-browser a chance to close its daemon, but don't depend on its state.
if command -v agent-browser >/dev/null && [[ -d runtime/ab ]]; then
  timeout 5s agent-browser dashboard stop >/dev/null 2>&1 || true
  timeout 5s agent-browser --session home close >/dev/null 2>&1 || true
fi

# These ports are reserved for this project. Kill their users, regardless of profile/PID files.
fuser -k -TERM 9222/tcp 4848/tcp >/dev/null 2>&1 || true
sleep 1
fuser -k -KILL 9222/tcp 4848/tcp >/dev/null 2>&1 || true
sleep 0.2

failed=0
if fuser 9222/tcp 4848/tcp >/dev/null 2>&1; then
  echo "ports are still occupied; cleanup incomplete" >&2
  failed=1
else
  # Forget saved tabs/windows, but leave cookies and the rest of each profile alone.
  for profile in runtime/profile/*; do
    [[ -d "$profile" && ! -L "$profile" ]] || continue
    rm -rf -- "$profile/Sessions"
    rm -f -- "$profile/Current Session" "$profile/Current Tabs" \
      "$profile/Last Session" "$profile/Last Tabs"
  done
fi

# Tailscale errors when disabling an absent route, so skip already-cleared ports.
if config=$(tailscale serve status --json); then
  for port in 9222 9223 443; do
    [[ "$port" != 443 || -f runtime/serve-443 ]] || continue
    if jq -e --arg port "$port" '.TCP[$port] != null' <<<"$config" >/dev/null; then
      if [[ "$port" == 9222 ]]; then option=--tcp=9222; else option=--https="$port"; fi
      sudo tailscale serve "$option" off || failed=1
    fi
  done
else
  failed=1
fi
if (( failed )); then
  echo "fix the errors above and run ./stop.sh again" >&2
  exit 1
fi
rm -f runtime/chromium.pid runtime/started runtime/agent-attached \
  runtime/dashboard-started runtime/serve-9222 runtime/serve-9223 runtime/serve-443

echo "cleared (tabs reset; profile and logins kept in runtime/profile/)"
