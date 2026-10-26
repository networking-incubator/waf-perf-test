#!/usr/bin/env bash
#
# install-all.sh - The default way to prepare a cluster for this harness.
# Installs every prerequisite, in order, then verifies.
#
#   scripts/prereqs/install-all.sh
#
# Opinionated on purpose: it detects the platform, takes the Istio route that
# platform expects, and installs the operator from its published chart. Nothing
# needs to be set first. Each tunable it uses has a default in lib.sh, and each
# step is a no-op when its piece is already present, so re-running is safe.
#
# This is a cluster change, not a measurement step. Run it before the session
# you intend to report, never between a baseline and a WAF-on run — installing
# or upgrading Istio restarts the gateway proxy and invalidates the comparison.
#
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
# shellcheck source=../../lib.sh
source ./lib.sh
preflight
require_platform_match

log "Platform: ${PLATFORM} ($("${PLATFORM_DETECTED}" && echo detected || echo "from PLATFORM"))"
if [[ "${PLATFORM}" == "openshift" ]]; then
  log "Plan: GatewayClass '${GATEWAY_CLASS}' -> cluster installs OSSM -> operator chart"
  log "      Gateway API CRDs ship with the cluster; Istio versions are the cluster's choice."
else
  log "Plan: Gateway API ${GATEWAY_API_VERSION} -> Istio ${ISTIO_VERSION} (${ISTIO_PROFILE}) -> operator chart"
fi
log "Operator chart: ${CORAZA_CHART_VERSION:-newest in the repo index} into '${CORAZA_NAMESPACE}'"
echo

# OpenShift ships the Gateway API CRDs; install-gateway-api.sh refuses there.
if ! cluster_is_openshift; then
  ./scripts/prereqs/install-gateway-api.sh
fi
./scripts/prereqs/install-istio.sh
./scripts/prereqs/install-operator.sh

echo
./scripts/prereqs/check.sh
