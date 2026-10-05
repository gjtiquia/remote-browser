# remote browser

- a way to remotely use a browser on a computer that running at home
- a way for agents to use the same browser as well remotely
- secured via tailscale

## pre-requisites

- `chromium` (fedora: install via `dnf`, executable is `chromium-browser`)
- [`node` via `nvm`](https://www.nvmnode.com/)
- [agent-browser](https://github.com/vercel-labs/agent-browser)
- [tailscale](https://tailscale.com/) connected, with MagicDNS / HTTPS enabled
- `jq`, `curl`, and `fuser` (fedora: `dnf install psmisc` for `fuser`)

## usage

```bash
./start.sh
./stop.sh
```

- starts at `about:blank`; stop clears tabs but keeps logins
- follow the instructions printed by `start.sh`
- `stop.sh` deliberately kills users of local ports `9222` and `4848`; reserve these ports for this project
- runtime files and the persistent browser profile live in gitignored `./runtime/`

