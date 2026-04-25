# CoreWAF Starter Kit

Point one host at CoreWAF, run one command, and you're up.

This repo is the customer-facing entry point to the CoreWAF Web Application
Firewall service. Run a single curl-pipe-to-bash, answer two prompts, and a
self-bootstrapping data plane registers with the CoreWAF backend and starts
protecting your traffic.

## Quick start

```bash
curl -fsSL https://raw.githubusercontent.com/ext-corero/corewaf-starter-kit/main/bootstrap.sh | bash
```

That clones the kit, walks you through two prompts (your **org scope ID**
and a **single observability base URL**) plus an optional comment, writes
`config.ini`, and runs `docker compose up -d`.

For the friendliest UI install [`gum`](https://github.com/charmbracelet/gum)
first; the bootstrap and installer both surface gum-styled prompts and
spinners when it's available, with plain-text fallbacks when it isn't.

### Other ways to run the install

| Use case | Command |
|---|---|
| Already cloned the repo | `cd corewaf-starter-kit && ./scripts/install.sh` |
| Don't bring up the stack — just write `config.ini` | `... bootstrap.sh \| NO_UP=1 bash` (or `./scripts/install.sh --no-up`) |
| Bypass prompts entirely | Copy `config.ini.example` to `config.ini`, edit, then `docker compose up -d` |

> An API-key-driven curl bootstrap (`curl -fsSL ... | sh -s -- --api-key=...`)
> replaces interactive prompts once the Zero Trust tunnel ships — same two
> values; the API key carries them automatically.

## What runs on your host

| Stage | Container | Purpose |
|---|---|---|
| 0 | `template-source` (one-shot) | Pulls Caddy/Alloy templates out of the `caddy-waf` image into a shared docker volume. Exits. |
| 1 | `discover` (privileged, one-shot) | Probes hardware, validates prerequisites, computes a stable instance name. Exits. |
| 2 | `templates` (one-shot) | Renders the runtime configuration from your `config.ini` plus discovery output. Exits. |
| 3 | `caddy` + `caddy-bridge` (long-running) | Caddy boots in pre-provisioning mode; the bridge registers with CoreWAF and waits. Once the backend provisions, traffic flows. |
| 4 | `alloy` + `valkey` (long-running, parallel) | Telemetry begins flowing immediately, regardless of provisioning state. |

## Requirements on your host

- Docker, with the running user able to use the socket.
- `git` CLI installed.
- Outbound network reach to GHCR (image pulls) and your CoreWAF backend.

That's it. Everything else runs in containers.

## License

Apache-2.0 — see `LICENSE`.
