# tunnel-client — kit-side WG enrollment + lifecycle.
#
# Single shell script entrypoint. Drives:
#   1. provisioning token redemption (one-shot, on first boot)
#   2. WG keypair generation (one-shot, persisted across restarts)
#   3. wg0 interface bring-up + keepalive
#   4. rendering apiEndpoint/zeroTrustApiKey/etc. into runtime/.env
#      so the bridge picks them up at start-up.

FROM alpine:3.21

RUN apk add --no-cache \
        wireguard-tools \
        iptables \
        iproute2 \
        curl \
        jq \
        bash \
        tini

WORKDIR /opt/tunnel-client
COPY tunnel-up.sh ./
COPY healthcheck.sh ./
RUN chmod +x tunnel-up.sh healthcheck.sh

# tini reaps wg-quick sub-processes cleanly on container shutdown.
ENTRYPOINT ["/sbin/tini", "--", "/opt/tunnel-client/tunnel-up.sh"]
