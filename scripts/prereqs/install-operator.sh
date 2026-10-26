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

# An install interrupted partway (Ctrl-C, a pod that never schedules, a killed
# CI step) leaves the release wedged in pending-install, and every later
# attempt fails with "another operation is in progress" instead of recovering.
# Clear it here rather than making the caller work that out.
release_status="$(helm status "${CORAZA_RELEASE}" -n "${CORAZA_NAMESPACE}" \
  -o json 2>/dev/null | python3 -c 'import json,sys
try: print(json.load(sys.stdin)["info"]["status"])
except Exception: pass' 2>/dev/null || true)"
if [[ "${release_status}" == pending-* ]]; then
  warn "previous attempt left release '${CORAZA_RELEASE}' in '${release_status}'; removing it first"
  helm uninstall "${CORAZA_RELEASE}" -n "${CORAZA_NAMESPACE}" >/dev/null 2>&1 || true
fi

args=(upgrade --install "${CORAZA_RELEASE}" "${CORAZA_CHART}"
      --namespace "${CORAZA_NAMESPACE}" --create-namespace
      --wait --timeout 10m)

[[ -n "${CORAZA_CHART_VERSION}" ]] && args+=(--version "${CORAZA_CHART_VERSION}")

# Override the image when the published one cannot run here — the release is
# linux/amd64 only, so an arm64 cluster needs a locally built one.
[[ -n "${CORAZA_IMAGE_REPO}" ]] && args+=(--set "image.repository=${CORAZA_IMAGE_REPO}")
[[ -n "${CORAZA_IMAGE_TAG}"  ]] && args+=(--set "image.tag=${CORAZA_IMAGE_TAG}")

# A cluster whose nodes are not amd64 cannot pull the published image at all.
# Catch it before a ten-minute --wait ends in ImagePullBackOff.
node_arch="$("${CLI}" get nodes -o jsonpath='{.items[0].status.nodeInfo.architecture}' 2>/dev/null || true)"
if [[ "${node_arch}" != "amd64" && -z "${CORAZA_IMAGE_REPO}" ]]; then
  err "cluster nodes are '${node_arch}' but the published operator image is linux/amd64 only."
  err "Build the operator for ${node_arch} and set CORAZA_IMAGE_REPO / CORAZA_IMAGE_TAG."
  err "See 'Architectures' in docs/prerequisites.md."
  exit 1
fi

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

# Helm installs the chart's crds/ on first install and NEVER touches them on
# upgrade. Upgrading the chart, or switching to a locally built operator, then
# leaves new code running against old CRDs. That failed here as RuleSource
# status patches returning "not found", because the older CRD had no status
# subresource — an error that names the object, not the schema, and sends you
# looking in the wrong place. Applying them is idempotent; do it every time.
if [[ -d "${CORAZA_CHART}/crds" ]]; then
  log "Applying the chart's CRDs (helm skips these on upgrade)"
  "${CLI}" apply -f "${CORAZA_CHART}/crds/" >/dev/null
else
  chart_crds="$(mktemp -d)"
  if helm pull "${CORAZA_CHART}" ${CORAZA_CHART_VERSION:+--version "${CORAZA_CHART_VERSION}"} \
       --untar --untardir "${chart_crds}" >/dev/null 2>&1 \
     && compgen -G "${chart_crds}"/*/crds/*.yaml >/dev/null; then
    log "Applying the chart's CRDs (helm skips these on upgrade)"
    "${CLI}" apply -f "${chart_crds}"/*/crds/ >/dev/null
  else
    warn "could not fetch the chart's CRDs to reapply them; upgrades may leave them stale"
  fi
  rm -rf "${chart_crds}"
fi

# No f-string: backslash escapes inside an f-string expression are a syntax
# error before Python 3.12, and this silently printed "unknown" because of it.
installed="$(helm list -n "${CORAZA_NAMESPACE}" -o json 2>/dev/null | python3 -c '
import json, sys
for r in json.load(sys.stdin):
    if r.get("name") == sys.argv[1]:
        print("chart %s, app %s" % (r.get("chart"), r.get("app_version")))
        break
else:
    print("unknown")' "${CORAZA_RELEASE}" 2>/dev/null || echo unknown)"

ok "Coraza operator installed (${installed})."
warn "Record that version in any report — the chart version is part of what the number describes."
log "Verify the whole stack: scripts/prereqs/check.sh"
