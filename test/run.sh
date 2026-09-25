#!/usr/bin/env bash
# Build the fresh-machine image and run the end-to-end install test in it.
#   test/run.sh                    uses ubuntu:24.04
#   BASE=agentos-base:noble test/run.sh   any other bare image
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
BASE="${BASE:-ubuntu:24.04}"
docker build --network host --build-arg BASE="$BASE" -t agentos-e2e -f "$REPO/test/Dockerfile" "$REPO"

# Pass a corporate/sandbox HTTPS proxy + CA through when present (no-op on a normal laptop).
extra=()
if [ -n "${HTTPS_PROXY:-}" ]; then
  extra+=(-e HTTPS_PROXY -e https_proxy="${HTTPS_PROXY}" -e NO_PROXY -e no_proxy="${NO_PROXY:-}")
fi
for ca in "${SSL_CERT_FILE:-}" /root/.ccr/ca-bundle.crt; do
  if [ -n "$ca" ] && [ -f "$ca" ]; then
    extra+=(-v "$ca:/etc/agentos-test-ca.crt:ro"
            -e SSL_CERT_FILE=/etc/agentos-test-ca.crt -e CURL_CA_BUNDLE=/etc/agentos-test-ca.crt
            -e NODE_EXTRA_CA_CERTS=/etc/agentos-test-ca.crt -e npm_config_cafile=/etc/agentos-test-ca.crt
            -e GIT_SSL_CAINFO=/etc/agentos-test-ca.crt)
    break
  fi
done
docker run --rm --network host ${extra[@]+"${extra[@]}"} agentos-e2e
