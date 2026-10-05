# remote browser

- a way to remotely use a browser on a computer that running at home
- a way for agents to use the same browser as well remotely
- secured via tailscale

## pre-requisites

- `chromium` (fedora: via `dnf`)
- [`node` via `nvm`](https://www.nvmnode.com/)
- [agent-browser](https://github.com/vercel-labs/agent-browser)
- [tailscale](https://tailscale.com/) connected, with MagicDNS / HTTPS enabled
- `jq` and `curl`

## notes

uses ports `9222` and `443`

## usage

```bash
./start.sh
./stop.sh
```

- open the private tokenized HTTPS URL printed by agent-browser, select `home`, and log in yourself; don't share the dashboard token
- send the agent the printed tailscale IP and `webSocketDebuggerUrl`; the agent replaces `localhost` / `127.0.0.1` in that URL with the tailscale IP
- `start.sh` does nothing if the tracked browser is already running
- `stop.sh` removes this project's serve routes and stops its browser/session; it does nothing if already stopped
- if startup is interrupted or the browser crashes, run `./stop.sh` before starting again
- keep the laptop awake; run `./start.sh` again after reboot
- don't run start and stop simultaneously

## runtime

- `./runtime/` is gitignored
- `runtime/profile/` keeps cookies and logins between stops and starts
- `runtime/chromium.log` contains browser output
- `runtime/chromium.pid`, serve markers, and `runtime/agent-browser/` track this project's running services
- the browser profile is separate from your everyday chromium profile

