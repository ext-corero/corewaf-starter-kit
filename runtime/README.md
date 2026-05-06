# `runtime/` — kit-side runtime artifacts

Files in this directory are mounted into the kit's tunnel container
at `/workspace/runtime/` and read by the network-loader.

## `operator-ca.crt` (PEM)

The operator's root CA bundle. The kit dials the gateway over TLS at
first boot using this file; once `/reconnect` succeeds the gateway
returns its current CA (`rootCABundle`) and the network-loader
overwrites this file atomically so future boots pick up rotated CAs
automatically.

**Operators**: bake your CA into this file as part of release-prep
before signing the git tag customers consume.

**Fixture / dev**: the multi-VM harness's `install-real-kit.sh`
overwrites this file dynamically with the running fixture gateway's
root.crt before the tunnel container starts.

If the file is missing, the network-loader logs a warning and falls
back to the system trust store (which on Alpine includes nothing
useful for a private CA — first contact will fail until the cert is
in place).
