#!/usr/bin/env bash
#
# install-gateway-api.sh - Install the Gateway API CRDs (Kubernetes only).
#
# OpenShift ships these with the cluster and the ingress operator reconciles
# them; applying a different bundle version there is reverted at best and
# breaks the managed gateway at worst. This script refuses to run on OpenShift.
#
#   scripts/prereqs/install-gateway-api.sh
#
# Env: GATEWAY_API_VERSION (default in lib.sh)
#
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
# shellcheck source=../../lib.sh
source ./lib.sh
preflight
require_platform_match

if cluster_is_openshift; then
  err "OpenShift manages the Gateway API CRDs itself — nothing to install here."
  exit 1
fi

if has_crd gateways.gateway.networking.k8s.io; then
  installed="$("${CLI}" get crd gateways.gateway.networking.k8s.io \
    -o jsonpath='{.metadata.annotations.gateway\.networking\.k8s\.io/bundle-version}' 2>/dev/null)"
  ok "Gateway API CRDs already installed (bundle ${installed:-unknown}). Leaving them alone."
  exit 0
fi

log "Installing Gateway API CRDs ${GATEWAY_API_VERSION}"
# The standard channel carries Gateway and HTTPRoute, which is all the harness
# uses. The experimental channel would also work but moves between releases.
"${CLI}" kustomize \
  "github.com/kubernetes-sigs/gateway-api/config/crd?ref=${GATEWAY_API_VERSION}" \
  | "${CLI}" apply -f -

"${CLI}" wait --for=condition=Established crd/gateways.gateway.networking.k8s.io --timeout=60s
ok "Gateway API ${GATEWAY_API_VERSION} installed. Next: scripts/prereqs/install-istio.sh"
