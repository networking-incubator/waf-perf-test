#!/usr/bin/env bash
#
# uninstall-operator.sh - Remove the Coraza operator and the test namespace,
# undoing scripts/prereqs/install-operator.sh and scripts/setup.sh.
#
#   scripts/prereqs/uninstall-operator.sh            # prompt, then remove
#   scripts/prereqs/uninstall-operator.sh --yes      # no prompt
#   scripts/prereqs/uninstall-operator.sh --keep-crds
#
# Deliberately NOT the mirror of install-all.sh. Istio and the GatewayClass are
# left alone:
#   - On OpenShift the ingress operator owns the Istio control plane; deleting
#     the GatewayClass does not uninstall OSSM, and removing OSSM by hand hits
#     every Gateway on the cluster, not just this harness's.
#   - On Kubernetes, 'istioctl uninstall' is slow to undo and slower to redo,
#     and nothing else here depends on it being gone.
# Remove those by hand if you really want to, and read install-istio.sh first.
#
# Env: NAMESPACE, CORAZA_NAMESPACE, CORAZA_RELEASE (defaults in lib.sh)
#
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
# shellcheck source=../../lib.sh
source ./lib.sh
preflight

ASSUME_YES=false
KEEP_CRDS=false
for arg in "$@"; do
  case "${arg}" in
    -y|--yes)    ASSUME_YES=true;;
    --keep-crds) KEEP_CRDS=true;;
    *) echo "usage: uninstall-operator.sh [--yes] [--keep-crds]" >&2; exit 1;;
  esac
done

# The operator's ClusterRole and binding are Helm-managed and go with the
# release. The supplement is not: it is applied separately precisely so a
# 'helm upgrade' cannot revert it, which also means a 'helm uninstall' cannot
# remove it. Name it here or it outlives everything it was granted for.
SUPPLEMENT="coraza-kubernetes-operator-status-supplement"

log "This will delete, if present:"
echo "    namespace '${NAMESPACE}' (gateway, backend, loadgen, WAF custom resources)"
echo "    helm release '${CORAZA_RELEASE}' in '${CORAZA_NAMESPACE}', and that namespace"
echo "    clusterrole/clusterrolebinding '${SUPPLEMENT}'"
"${KEEP_CRDS}" || echo "    CRDs *.waf.k8s.coraza.io — and every Engine/RuleSet/RuleSource/RuleData"
echo "                  on the cluster, in any namespace, not only '${NAMESPACE}'"
echo "  Left alone: Istio / OSSM, the GatewayClass, and the Gateway API CRDs."
echo "  Results under ${RESULTS_DIR} are kept."
echo

if ! "${ASSUME_YES}"; then
  read -r -p "Type the namespace to confirm (${NAMESPACE}): " reply
  [[ "${reply}" == "${NAMESPACE}" ]] || { err "aborted"; exit 1; }
fi

# Order matters, and getting it wrong wedges the cluster rather than failing.
# Engines carry a finalizer that only the operator clears. Delete the operator
# first and the namespace then hangs in Terminating with nothing left to
# release it; delete the CRDs first and the same deletion blocks on CRs whose
# finalizers can no longer run. So: custom resources while the operator is
# still watching, then the operator, then the CRDs.
log "1/4 Removing the test namespace (while the operator can still clear finalizers)"
./scripts/teardown.sh

# The namespace delete returns before it finishes, and the CRs inside it are
# the ones whose finalizers need the operator. Waiting here is what makes the
# ordering above real rather than nominal.
if "${CLI}" get namespace "${NAMESPACE}" >/dev/null 2>&1; then
  log "    waiting for '${NAMESPACE}' to finish terminating"
  "${CLI}" wait --for=delete "namespace/${NAMESPACE}" --timeout=180s || \
    warn "'${NAMESPACE}' is still terminating; a stuck finalizer will block the CRD delete below"
fi

log "2/4 Uninstalling the operator release '${CORAZA_RELEASE}'"
if command -v helm >/dev/null 2>&1 && \
   helm status "${CORAZA_RELEASE}" -n "${CORAZA_NAMESPACE}" >/dev/null 2>&1; then
  helm uninstall "${CORAZA_RELEASE}" -n "${CORAZA_NAMESPACE}"
else
  warn "no helm release '${CORAZA_RELEASE}' in '${CORAZA_NAMESPACE}' — skipping"
fi
"${CLI}" delete namespace "${CORAZA_NAMESPACE}" --ignore-not-found

log "3/4 Removing the supplementary RBAC"
"${CLI}" delete clusterrolebinding "${SUPPLEMENT}" --ignore-not-found
"${CLI}" delete clusterrole "${SUPPLEMENT}" --ignore-not-found

if "${KEEP_CRDS}"; then
  log "4/4 Keeping the CRDs (--keep-crds)"
else
  # helm uninstall never touches crds/ — by design, since a chart cannot know
  # whether another release still needs them. They are always a manual step.
  log "4/4 Removing the Coraza CRDs"
  for crd in engines rulesets rulesources ruledata; do
    "${CLI}" delete crd "${crd}.waf.k8s.coraza.io" --ignore-not-found
  done
fi

ok "Uninstall complete. Verify what is left: scripts/prereqs/check.sh"
log "Reinstall with: scripts/prereqs/install-all.sh"
