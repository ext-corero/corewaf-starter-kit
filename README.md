# CoreWAF Starter Kit

Point one host at CoreWAF, run one command, and you're up.

This repo is the customer-facing entry point to the CoreWAF Web Application Firewall service. Clone it, supply an API key, and `docker compose up -d` brings up a self-bootstrapping data plane that registers with the CoreWAF backend and starts protecting your traffic.

## What's in here

A docker-compose stack with one job: bring up a CoreWAF data plane on your host and connect it to the service. No tools to install beyond Docker — discovery, templating, registration, and lifecycle are all driven by the orchestrator running in a container.

## Quick start

```bash
git clone https://github.com/ext-corero/corewaf-starter-kit.git
cd corewaf-starter-kit
./scripts/install.sh
```

That walks you through two prompts (your **org scope ID** and a **single observability base URL**) plus an optional comment, writes `config.ini`, and runs `docker compose up -d`. Re-run later with `--no-up` to update the config without restarting the stack.

If you'd rather not use the installer, copy `config.ini.example` to `config.ini` by hand and run `docker compose up -d` directly.

> An API-key-driven curl bootstrap (`curl -fsSL ... | sh`) replaces this script once the Zero Trust tunnel ships. Same two values; the API key carries them automatically.

## What runs on your host

| Stage | Container | Purpose |
|---|---|---|
| 1 | `discover` (privileged, one-shot) | Probes hardware, validates prerequisites, computes a stable instance name. Exits. |
| 2 | `templates` (one-shot) | Renders the runtime configuration from your `config.ini` plus discovery output. Exits. |
| 3 | `caddy` + `caddy-bridge` (long-running) | Caddy starts empty; the bridge registers with CoreWAF and waits to be provisioned. Once provisioned, traffic flows. |
| 4 | `alloy` + supporting services (long-running, parallel) | Telemetry begins flowing immediately, regardless of provisioning state. |

See [`docs/requirements.md`](docs/requirements.md) for the full design.

## Requirements on your host

- Docker, with the running user able to use the socket.
- `git` CLI installed.
- Outbound network reach to the CoreWAF service.

That's it. Everything else runs in containers.

## License

Apache-2.0 (pending — see `LICENSE`).
