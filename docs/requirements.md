# `corewaf-waf-instance` — Requirements & Boot Flow

**Status**: Draft v1 (agreed)
**Date**: 2026-04-25
**Scope**: the customer-facing data-plane deployment — the only CoreWAF artifact a customer ever touches.

---

## 1. Purpose

This project is the **single contact point** between an end customer and the CoreWAF platform. A customer with a compute resource runs a curl bootstrap, which lands this project on the host; `docker compose up -d` brings up a self-bootstrapping data plane that hooks into the WAF-as-a-service backend.

Everything that is not part of that customer-facing slice — Juice Shop, attack tooling, integration tests — lives in a separate, internal-only repo (see §3, §10).

---

## 2. Customer journey

1. Customer runs a one-line curl bootstrap (eventually with an API key argument).
2. The bootstrap downloads / git-syncs the **customer-facing repo** onto the host.
3. Customer config is collected:
   - **Today**: the curl script uses `gum` (charmbracelet) as a TUI to prompt the customer for the inputs in §5 and writes a `config.ini`.
   - **Eventually**: the API key authenticates a Zero Trust tunnel to the backend; the discovery service auto-populates `config.ini` and the customer never types anything.
4. Customer runs `docker compose up -d`.
5. Stack self-bootstraps. The Caddy Bridge registers with the WAF backend and waits to be provisioned. Everything else (Alloy → Loki/Mimir/Minio, supporting services) is up and shipping telemetry **immediately**, in parallel with that wait.
6. Once the backend provisions Caddy, traffic begins flowing.

---

## 3. Repo split

The current repo is being bisected.

| Repo | Visibility | Hosting | Contents |
|---|---|---|---|
| **Customer-facing** (new, thin) | private now, **public on GitHub** in coming days | GitHub | Only what the curl bootstrap fetches. End-to-end runnable with `docker compose up -d`. Designed to be safe to publish from day one. |
| **Internal** (today's repo, repurposed) | private, stays private | GitLab + GitHub | Juice Shop, attack tooling (Nikto, wafw00f, ZAP, Wfuzz, sqlmap), integration tests targeting the customer-facing stack from outside. |

**Hard rule**: nothing internal-only (hostnames, internal registries, secrets, internal URLs) leaks into the customer-facing repo. The repo is built to be public from day one — even while we keep it private for a few more days.

---

## 4. Boot sequence on the customer host

All stages run as docker containers; orchestrator-driven.

| # | Stage | Privileges | Lifecycle | Purpose |
|---|---|---|---|---|
| 1 | **Discovery** (`orchestrator discover`) | privileged; `/proc`, `/sys`, host paths | one-shot, exits | Three outputs into a shared `hwinfo` docker volume: <br>(a) **performance envelope** — CPU, memory, anything needed to size the instance and surface limits to the backend; <br>(b) **prereq sanity check** — `git` CLI present, Docker installed and the running user can use the socket, network info collected (validation deferred — best-effort today, reach test to backend eventually); <br>(c) **stable instance UUID** derived from `machine_id` + hardware fingerprint, owned by the orchestrator (see §13, directional note 1). |
| 2 | **Template assembly** (`orchestrator templates render`) | unprivileged | one-shot, exits | Aggregates `config.ini` (customer-edited) + bootstrap variables + discovery output → final runtime config files (Caddyfile, Alloy config, compose env). Replaces the older Alloy-component pattern (see §8). |
| 3 | **Caddy + Caddy Bridge** | unprivileged | long-running | Caddy starts with empty config. Bridge reads `hwinfo` (incl. instance UUID + org scope ID), POSTs registration to the WAF backend, heartbeats, and **waits**. On the provisioning webhook → Bridge pushes config to Caddy's Admin API → Caddy serves traffic. |
| 4 | **Alloy + supporting services** | unprivileged | long-running, **starts in parallel with #3** | Alloy connects to Loki/Mimir/Minio (eventually over the Zero Trust tunnel) and ships telemetry immediately, regardless of Caddy's provisioning state. |

**Concurrency rule**: stage 4 is gated only on stages 1–2 (host facts + rendered config). Stage 3's "waiting for provisioning" must never hold back telemetry.

**Failure rule**: if discovery's sanity check fails (no `git`, no docker socket access, missing `org_scope_id`), the boot **halts visibly** at stage 1. No partial deployment, no half-started telemetry. The failure surfaces in `docker compose up` output and in the discovery container's exit code.

---

## 5. Inputs the customer host receives

| Input | Source — today | Source — eventual |
|---|---|---|
| `config.ini` (customer settings) | `gum`-driven curl script prompts customer | curl uses API key → Zero Trust tunnel → discovery service auto-populates |
| `org_scope_id` | typed into `config.ini` (intentionally inconvenient — see §6) | embedded in the API key |
| API key | n/a (deferred) | argument to the curl bootstrap |
| Backend endpoints (Loki, Mimir, Minio, api-server) | from `config.ini`, templated into runtime config | from tunnel + discovery |
| Bootstrap variables (orchestrator's `/etc/bootstrap`-shaped) | rendered by curl from `config.ini` | rendered from API-key context + tunnel |
| Stable instance UUID | computed by `orchestrator discover` at boot | same |
| Host facts (perf envelope) | `orchestrator discover` | same |

Today's `alloy/endpoints.json` (which hardcodes `192.168.200.142`) is the **anti-pattern**: it bakes endpoints into a checked-in file. The new design pulls every backend URL from `config.ini` → bootstrap variables → templates render.

---

## 6. Backend communication

- **Today**: the customer's compute resource is assumed to be in the same network as the WAF backend. No tunnel. Communication uses the project registry, project Loki/Mimir/Minio, project api-server.
- **Eventually**: all customer→backend traffic flows over a **Zero Trust tunnel** brought up by the curl bootstrap.
  - The API key is a single-use crypto token per instance.
  - It carries the `org_scope_id` (so the customer no longer types it).
  - It is validated against prior runs — first-use binding sticks; once an instance registers with a given key, that pairing is the permanent record. Re-issuing requires backend action.
  - The orchestrator and the customer-facing stack consume this; they do not implement the tunnel.

**Implication for now**: nothing in templates or compose may bake in a backend URL or scope ID. Everything sourced from variables, even in the demo configuration.

---

## 7. Image source

- **Working assumption**: while the customer + backend share a network, images come from the **project registry**.
- **End state**: images come from **public registries** — GHCR for our images (orchestrator, Caddy Bridge), Docker Hub for upstream images we already use (`caddy`, `valkey`, `grafana/alloy`, etc.).
- The flip from project-registry → public is forced by the public-on-GitHub move: a public repo cannot reference a private registry the customer can't reach. The customer-facing manifest must therefore be one variable away from each image source — no hard-coded internal-registry paths.
- §11 lays the groundwork: orchestrator and Caddy Bridge images publish to GHCR public from day one, so the eventual flip is a manifest edit, not a project.

---

## 8. Componentization — what didn't work, what we'll do

**What didn't work**: the Alloy dynamic-import pattern in `alloy/config.alloy`. Per-service Alloy fragments were discovered at runtime via Docker labels (`alloy.config.file` → `__meta_docker_container_label_alloy_config_file`) and pulled in with `import.file` from `/etc/alloy/config.d/`. The repo carries three half-finished iterations of this idea (`alloy/caddy-waf.alloy`, `alloy/caddy-waf.alloy.old`, `todo/config-new.alloy` at 508 lines unmerged) — evidence that the runtime-discovery approach didn't converge.

**What we'll do**: the orchestrator's template step renders **one static Alloy config** from versioned fragments at deploy time. Concatenation + variable substitution happen once, before Alloy starts. No discovery-time label scraping; no runtime composition. Per-service fragments are still owned by the service that needs them — the composition just moves from runtime to deploy time, where it's deterministic and debuggable.

The same principle applies to other componentized surfaces (Caddyfile fragments, compose includes): assemble at deploy time via templates, run a single rendered artifact.

---

## 9. Service manifest

The customer-facing stack uses one orchestrator manifest, **`service.json` v0.0.4**, declaring:

- `files` — what is reproducibly packaged (compose, templates, defaults).
- `variables` — values resolved from bootstrap + `config.ini` + discovery output.
- `docker.networks` / `docker.volumes` — including the shared `hwinfo` volume.
- `templates` — fragment → final-config mappings (Caddyfile, Alloy, compose `.env`).
- (Future, Track-3 in the orchestrator) secrets, dynamic DNS.

`services/core/caddy-instance/service.json` (today: v0.0.3) is the seed and gets bumped + extended into the customer-facing repo. The boot order it sketches (`hw-introspect` → `caddy` → `caddy-bridge`) matches §4, with `hw-introspect` replaced by `orchestrator discover`.

---

## 10. Internal repo (what does NOT go to the customer)

- **Juice Shop** service definition (used as a target for live demos).
- **Attack tooling**: Nikto, wafw00f, ZAP, Wfuzz, sqlmap recipes.
- **Integration tests** that drive the customer-facing stack from outside.
- Anything that exercises the public stack but isn't part of it.

These keep working against the public stack the same way an external user would, which is the point.

---

## 11. CI/CD additions (separate task track)

Each component repo extends its own pipeline. **No cross-repo coupling.**

| Repo | Existing | Add |
|---|---|---|
| `orchestrator` | GitLab → internal registry | GitHub Actions → **GHCR public**, same versioning scheme |
| `waf-caddy-bridge` | GitLab → internal registry | GitHub Actions → **GHCR public**, same versioning scheme |

**Versioning**: same scheme on both sides — no divergence unless we hit a hard blocker. `next-version.sh` (which queries the registry today) needs to consult both GitLab's registry and GHCR so versions don't drift.

**Visibility**: public on GHCR. Easier to pull, matches the long-term direction.

**Constraint**: existing GitLab pipeline must remain untouched and functional throughout.

---

## 12. Out of scope

- Implementing the Zero Trust tunnel itself (consume-only when it lands).
- Backend provisioning logic (lives in the WAF service center, not here).
- The master/bootstrap Docker image and the curl script itself — **last task**, after the stack and CI/CD are in place.
- Replacing or modifying the orchestrator's Track-1 surface; we consume it as-is. The instance-UUID feature (§13 note 1) is a new ask filed against the orchestrator repo, not implemented here.

---

## 13. Open questions & directional notes

### Open questions

- **Q1 — Discovery output wiring.** Which exact discovery fields the orchestrator's template/env layer exposes to templates, and under what namespace. Minimum: instance UUID + perf envelope + sanity-check status. Full surface TBD.
- **Q2 — Versioning sync.** Does `next-version.sh` query both GitLab and GHCR and pick the max, or anchor to one as primary?
- **Q3 — Customer-edit surface.** Enumerate the keys of `config.ini` precisely. Smallest possible surface — every key the customer touches is a key the eventual API-key flow has to be able to derive.
- **Q4 — Sanity-check failure UX.** How does the customer see "your host is missing git"? Stdout from the discovery container? `gum`-rendered summary at the curl-script step before the stack starts? Both?
- **Q5 — Curl-script home.** Lives in the customer-facing repo (chicken-and-egg with the public flip), or hosted separately (e.g., a `get.corewaf.io`-style endpoint)?

### Directional notes (decided, not open)

1. **Two-identity model — local + remote, harmonized.** Each instance carries two identities, by design:

   | | **Local identity** (`metadata.name`) | **Remote identity** (`metadata.uuid`) |
   |---|---|---|
   | Origin | Client-side, computed by `orchestrator discover` from `machine_id` + hardware fingerprint | Server-side, minted as `uuid4()` at registration |
   | Property | Deterministic, stable across reboots | Random, opaque, returned to the client |
   | Role | "Same server I was yesterday" — provable locally without the backend | Registered-resource handle the bridge stores; eventual crypto anchor |
   | Customer-visible | Yes (with optional free-form comment alongside) | No |

   The CRD already implements the remote half correctly (`waf/api/shared/crd/metadata.py:47-50` + `waf/api/caddy_api/models.py`). The work is on the **client side**: `orchestrator discover` emits a deterministic `instance_name` field in `discovery.json`; the bridge reads it via `hwinfo_loader` and uses it as `metadata.name` at registration, replacing today's `hw.hostname` fallback (`waf/caddy-bridge/src/services/registration.py:78-79`). Tracked across three tasks (orchestrator feature, bridge wiring, caddy-api doc harmonization).

   Customer-supplied **comment / description** rides alongside, sourced from `config.ini` → bridge env (`INSTANCE_COMMENT`) → `metadata.description` (already first-class on `BaseMetadata`, no API schema change).
2. **`hw-introspect` ≡ `orchestrator discover`.** Same thing, two iterations. The customer-facing stack uses `orchestrator discover` exclusively; the standalone `hw-introspect` image is retired.
3. **API-key model (eventual).** Single-use crypto token per instance, carrying `org_scope_id`. First-use binding sticks: an instance + its key are paired permanently after first registration. Re-issuing requires backend action. Near-term irrelevant; design must not bake `org_scope_id` into a place that couldn't later be replaced by a key-derived value.

---

*Draft v1 — agreed in conversation 2026-04-25. Update or supersede as decisions firm up.*
