#!/usr/bin/env bash
#
# install-operator.sh - Install the Coraza Kubernetes Operator from its
# published Helm chart. The chart carries its own CRDs.
#
#   scripts/prereqs/install-operator.sh
#
# Env: CORAZA_CHART_VERSION (pin it for a reportable run), CORAZA_NAMESPACE,
#      CORAZA_RELEASE, CORAZA_CHART_REPO (defaults in lib.sh)
#
# This installs a release build. To test operator changes you have not shipped,
# use 'make deploy' in the operator repo instead and skip this script.
#
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
# shellcheck source=../../lib.sh
source ./lib.sh
preflight
require_platform_match
require_cmd helm

has_crd wasmplugins.extensions.istio.io || {
  err "Istio is not installed — the operator has nothing to write WasmPlugins to."
  err "Run scripts/prereqs/install-istio.sh first."
  exit 1
}

log "Adding chart repo ${CORAZA_CHART_REPO}"
helm repo add "${CORAZA_CHART_REPO_NAME}" "${CORAZA_CHART_REPO}" --force-update
helm repo update "${CORAZA_CHART_REPO_NAME}"

args=(upgrade --install "${CORAZA_RELEASE}" "${CORAZA_CHART}"
      --namespace "${CORAZA_NAMESPACE}" --create-namespace
      --wait --timeout 10m)

[[ -n "${CORAZA_CHART_VERSION}" ]] && args+=(--version "${CORAZA_CHART_VERSION}")

if cluster_is_openshift; then
  # openshift.enabled drops runAsUser/fsGroup so the SCC can assign its own UID.
  # The revision must match the control plane the ingress operator created, or
  # the WasmPlugin is written against a revision no gateway proxy watches.
  log "OpenShift: targeting Istio revision '${OCP_ISTIO_REVISION}'"
  args+=(--set openshift.enabled=true --set "istio.revision=${OCP_ISTIO_REVISION}")
fi

# The chart's ServiceMonitor needs the Prometheus Operator CRD; without it the
# install fails on an unknown kind. collect.sh is the only consumer, so make it
# conditional rather than a hard prerequisite.
if has_crd servicemonitors.monitoring.coreos.com; then
  args+=(--set metrics.serviceMonitor.enabled=true)
else
  warn "No ServiceMonitor CRD — installing without metrics.serviceMonitor"
fi

log "Installing ${CORAZA_CHART} into '${CORAZA_NAMESPACE}'"
helm "${args[@]}"

installed="$(helm list -n "${CORAZA_NAMESPACE}" -f "^${CORAZA_RELEASE}\$" \
  -o json 2>/dev/null | python3 -c 'import json,sys
r=json.load(sys.stdin)
print(f"chart {r[0][\"chart\"]}, app {r[0][\"app_version\"]}" if r else "unknown")' 2>/dev/null || echo unknown)"

ok "Coraza operator installed (${installed})."
warn "Record that version in any report — the chart version is part of what the number describes."
log "Verify the whole stack: scripts/prereqs/check.sh"
