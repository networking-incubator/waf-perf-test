#!/usr/bin/env bash
#
# check.sh - Verify everything the harness assumes is already on the cluster.
#
# setup.sh does not check any of this: it applies the Gateway and then waits on
# a Programmed condition that, with no GatewayClass or no Istio, never arrives.
# That failure looks like a hang. This tells you which piece is missing in a
# couple of seconds instead.
#
#   scripts/prereqs/check.sh          # report, exit 1 if anything is missing
#
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
# shellcheck source=../../lib.sh
source ./lib.sh
preflight

missing=0
# $1 label, $2 fix hint, then the predicate as the remaining arguments.
check() {
  local label="$1" fix="$2"; shift 2
  if "$@" >/dev/null 2>&1; then
    ok "${label}"
  else
    err "${label} — ${fix}"
    missing=$((missing + 1))
  fi
}

log "Platform: ${PLATFORM} ($("${PLATFORM_DETECTED}" && echo detected || echo "from PLATFORM"), CLI '${CLI}', gateway class '${GATEWAY_CLASS}')"
require_platform_match

check "Gateway API CRDs" \
  "scripts/prereqs/install-gateway-api.sh" \
  has_crd gateways.gateway.networking.k8s.io

check "GatewayClass '${GATEWAY_CLASS}' exists" \
  "scripts/prereqs/install-istio.sh" \
  "${CLI}" get gatewayclass "${GATEWAY_CLASS}"

# An unaccepted GatewayClass still accepts Gateways; they just never program.
check "GatewayClass '${GATEWAY_CLASS}' accepted by its controller" \
  "its controller has not accepted it — ${CLI} describe gatewayclass ${GATEWAY_CLASS}" \
  "${CLI}" wait --for=condition=Accepted "gatewayclass/${GATEWAY_CLASS}" --timeout=5s

# The module under test is delivered as a WasmPlugin. No CRD, no measurement.
check "Istio WasmPlugin CRD" \
  "Istio is not installed — scripts/prereqs/install-istio.sh" \
  has_crd wasmplugins.extensions.istio.io

for crd in engines rulesets rulesources; do
  check "Coraza CRD ${crd}.waf.k8s.coraza.io" \
    "operator not installed — scripts/prereqs/install-operator.sh" \
    has_crd "${crd}.waf.k8s.coraza.io"
done

check "Coraza operator available in '${CORAZA_NAMESPACE}'" \
  "operator CRDs exist but no manager is running — ${CLI} get pods -n ${CORAZA_NAMESPACE}" \
  "${CLI}" wait --for=condition=Available deploy -l app.kubernetes.io/name=coraza-kubernetes-operator \
  -n "${CORAZA_NAMESPACE}" --timeout=5s

# Optional, and only a warning: collect.sh needs it, a latency run does not.
if "${CLI}" get crd servicemonitors.monitoring.coreos.com >/dev/null 2>&1; then
  ok "ServiceMonitor CRD (metrics collection available)"
else
  warn "No ServiceMonitor CRD — scripts/collect.sh will have nothing to scrape"
fi

echo
if (( missing > 0 )); then
  err "${missing} prerequisite(s) missing. Install them: scripts/prereqs/install-all.sh"
  err "Details and the manual equivalents: docs/prerequisites.md"
  exit 1
fi
ok "All prerequisites present. Next: scripts/setup.sh"
