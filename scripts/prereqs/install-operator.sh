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
#      CORAZA_IMAGE_REPO / CORAZA_IMAGE_TAG override the chart's image — needed
#      on arm64, where the chart's ghcr.io release is amd64-only.
#      CORAZA_CRD_DIR must accompany them, pointing at the config/crd/bases of
#      the revision that image was built from. The chart's CRDs are pinned to
#      the chart; a newer operator needs fields they do not define, and the
#      mismatch surfaces three steps later as a RuleSet that never goes Ready.
#      See 'Architectures' in docs/prerequisites.md.
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

# Override the image when the chart's own cannot run here — its ghcr.io
# release is linux/amd64 only, so an arm64 cluster needs the multi-arch
# Konflux build or one you built yourself.
#
# Tracked, because an image that is not the chart's is also the case where the
# chart's CRDs are the wrong ones: the two ship together and only match when
# both come from the same revision. Checked once below, after the fallback
# that reuses an already-deployed image has had its say.
custom_image=false
[[ -n "${CORAZA_IMAGE_REPO}" ]] && { args+=(--set "image.repository=${CORAZA_IMAGE_REPO}"); custom_image=true; }
[[ -n "${CORAZA_IMAGE_TAG}"  ]] && args+=(--set "image.tag=${CORAZA_IMAGE_TAG}")

# A cluster with no amd64 node cannot pull the published image at all. Catch
# that before a ten-minute --wait ends in ImagePullBackOff.
#
# Every node, not just the first: a mixed-architecture cluster can schedule the
# operator on an amd64 node, so one arm64 node is no reason to refuse. And
# listing nodes is a cluster-scoped read that plenty of namespace-scoped
# credentials do not have — when the list comes back empty we cannot tell
# "no amd64 nodes" from "not allowed to look", so proceed rather than block on
# a guess.
node_arches="$("${CLI}" get nodes -o jsonpath='{range .items[*]}{.status.nodeInfo.architecture}{"\n"}{end}' 2>/dev/null | sort -u | tr '\n' ' ' || true)"
if [[ -z "${node_arches// /}" ]]; then
  warn "cannot read node architectures; skipping the image-architecture check"
elif [[ " ${node_arches} " != *" amd64 "* && -z "${CORAZA_IMAGE_REPO}" ]]; then
  node_arch="${node_arches% }"
  # An image is already deployed here, so someone solved this before. Re-running
  # the installer (or install-all.sh, which passes no overrides of its own)
  # must not refuse to proceed on a cluster that is already working.
  deployed_image="$("${CLI}" get deploy -n "${CORAZA_NAMESPACE}" \
    -l app.kubernetes.io/name=coraza-kubernetes-operator \
    -o jsonpath='{.items[0].spec.template.spec.containers[0].image}' 2>/dev/null || true)"
  if [[ -n "${deployed_image}" && "${deployed_image##*/}" == *:* ]]; then
    log "Keeping the operator image already deployed: ${deployed_image}"
    args+=(--set "image.repository=${deployed_image%:*}" --set "image.tag=${deployed_image##*:}")
    custom_image=true
  else
    err "cluster nodes are '${node_arch}' but the chart's ghcr.io release image is linux/amd64 only."
    err "Pick an image that runs here and set CORAZA_IMAGE_REPO / CORAZA_IMAGE_TAG, plus"
    err "CORAZA_CRD_DIR for the matching source revision. Either:"
    err "  - a multi-arch build from ${CORAZA_IMAGE_ARM64_HINT}"
    err "    (staging: commit-SHA tags, no 'latest', builds are garbage-collected), or"
    err "  - one you build yourself."
    err "See 'Architectures' in docs/prerequisites.md."
    exit 1
  fi
fi

# The pairing, stated once where both halves are known. Not fatal: a build
# close enough to the chart works fine, and only you know which revision the
# image came from. But this combination is what produces a WAF that installs
# cleanly, reports Ready on nothing, and times out in waf.sh much later.
if "${custom_image}" && [[ -z "${CORAZA_CRD_DIR}" ]]; then
  warn "running an operator image that is not the chart's, against the chart's CRDs."
  warn "Set CORAZA_CRD_DIR=<checkout>/config/crd/bases for the revision that image was"
  warn "built from, or the RuleSet may never go Ready."
  warn "See 'Architectures' in docs/prerequisites.md."
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
#
# CORAZA_CRD_DIR overrides the source. Reapplying the chart's CRDs is only a
# fix while the image is the chart's: against a locally built operator the
# chart's copies are the stale ones, so this step was faithfully reinstalling
# the very schema that broke it.
if [[ -n "${CORAZA_CRD_DIR}" ]]; then
  [[ -d "${CORAZA_CRD_DIR}" ]] || { err "CORAZA_CRD_DIR='${CORAZA_CRD_DIR}' is not a directory"; exit 1; }
  compgen -G "${CORAZA_CRD_DIR}/*.yaml" >/dev/null \
    || { err "no *.yaml in CORAZA_CRD_DIR='${CORAZA_CRD_DIR}'"; exit 1; }
  log "Applying CRDs from CORAZA_CRD_DIR (overrides the chart's)"
  # Server-side: these were first applied client-side by helm, so the existing
  # objects carry a last-applied-configuration that field management conflicts
  # with. --force-conflicts takes ownership rather than failing the install.
  "${CLI}" apply --server-side --force-conflicts -f "${CORAZA_CRD_DIR}/" >/dev/null
elif [[ -d "${CORAZA_CHART}/crds" ]]; then
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

# The chart renders the image as "{{ repository }}:{{ tag }}" and has no digest
# field, so a @sha256: reference cannot be passed through CORAZA_IMAGE_TAG.
# Read back what the node actually resolved instead: a commit-SHA tag in a
# staging registry can be rebuilt or collected, and the digest is the only
# thing that still identifies this binary afterwards.
resolved="$("${CLI}" get pods -n "${CORAZA_NAMESPACE}" \
  -l app.kubernetes.io/name=coraza-kubernetes-operator \
  -o jsonpath='{.items[0].status.containerStatuses[0].imageID}' 2>/dev/null || true)"
[[ -n "${resolved}" ]] && log "Running image: ${resolved}"

warn "Record the chart version and that image digest in any report — both are part"
warn "of what the number describes."
log "Verify the whole stack: scripts/prereqs/check.sh"
