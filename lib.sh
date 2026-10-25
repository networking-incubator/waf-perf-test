#!/usr/bin/env bash
#
# lib.sh - shared config + helpers for the Coraza WAF performance-testing harness.
# Sourced by the scripts under scripts/; not meant to be run directly.
#
set -euo pipefail

# --- paths ------------------------------------------------------------------
PT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS_DIR="${PT_ROOT}/manifests"
RULESETS_DIR="${MANIFESTS_DIR}/rulesets"
LOAD_PROFILES_DIR="${MANIFESTS_DIR}/load-profiles"
PAYLOADS_DIR="${LOAD_PROFILES_DIR}/payloads"
PAYLOADS_CONFIGMAP="${PAYLOADS_CONFIGMAP:-perf-payloads}"
SCENARIOS_DIR="${PT_ROOT}/scenarios"
RESULTS_DIR="${RESULTS_DIR:-${PT_ROOT}/results}"

# --- platform / cluster -----------------------------------------------------
PLATFORM="${PLATFORM:-kubernetes}"
case "${PLATFORM}" in
  kubernetes|k8s) PLATFORM="kubernetes"; CLI="${CLI:-kubectl}"; GATEWAY_CLASS="${GATEWAY_CLASS:-istio}";;
  openshift|ocp)  PLATFORM="openshift";  CLI="${CLI:-oc}";      GATEWAY_CLASS="${GATEWAY_CLASS:-openshift-default}";;
  *) echo "ERROR: unknown PLATFORM='${PLATFORM}'" >&2; exit 1;;
esac

# --- test topology ----------------------------------------------------------
NAMESPACE="${NAMESPACE:-waf-perf}"
GATEWAY_NAME="${GATEWAY_NAME:-perf-gateway}"
GATEWAY_SVC="${GATEWAY_SVC:-${GATEWAY_NAME}-${GATEWAY_CLASS}}"
# In-cluster URL the load generator hits (keeps client<->gateway hop internal).
TARGET_URL="${TARGET_URL:-http://${GATEWAY_SVC}.${NAMESPACE}.svc.cluster.local:80}"

# Load generator (fortio: open-model, HDR histograms -> no coordinated omission).
LOADGEN_IMAGE="${LOADGEN_IMAGE:-fortio/fortio:latest}"
LOADGEN_NAME="${LOADGEN_NAME:-loadgen}"

# WAF resource names.
ENGINE_NAME="${ENGINE_NAME:-perf-engine}"
RULESET_NAME="${RULESET_NAME:-perf-ruleset}"

# Observability (optional metric collection via collect.sh).
PROM_NAMESPACE="${PROM_NAMESPACE:-monitoring}"
PROM_SVC="${PROM_SVC:-prometheus-k8s}"
PROM_PORT="${PROM_PORT:-9090}"

WAIT_TIMEOUT="${WAIT_TIMEOUT:-180s}"

# --- prerequisites (scripts/prereqs/ only) ----------------------------------
# Read only by scripts/prereqs/*.sh. A measurement run never installs anything:
# keeping the installers out of setup.sh is what stops a cluster change from
# landing inside a measurement window. See docs/prerequisites.md.
#
# Gateway API CRDs. OpenShift ships its own set and the version below is
# ignored there; overriding it on OpenShift would fight the ingress operator.
GATEWAY_API_VERSION="${GATEWAY_API_VERSION:-v1.4.1}"
# Upstream Istio, Kubernetes only. Default tracks the version OpenShift 4.22
# installs for its managed Gateway API, so the two platforms stay comparable.
ISTIO_VERSION="${ISTIO_VERSION:-1.28.5}"
# minimal, not demo: the demo profile adds telemetry addons that compete for
# CPU with the proxy under test.
ISTIO_PROFILE="${ISTIO_PROFILE:-minimal}"
# OpenShift: creating a GatewayClass with this controller is what makes the
# cluster ingress operator install OSSM and an Istio control plane for it.
OCP_GATEWAY_CONTROLLER="${OCP_GATEWAY_CONTROLLER:-openshift.io/gateway-controller/v1}"
# The Istio revision the OpenShift ingress operator names its control plane.
# The operator chart must target the same revision or the WasmPlugin it writes
# is ignored by the gateway's proxy.
OCP_ISTIO_REVISION="${OCP_ISTIO_REVISION:-openshift-gateway}"

# Coraza operator Helm chart, published by the operator repo's release CI.
CORAZA_CHART_REPO="${CORAZA_CHART_REPO:-https://networking-incubator.github.io/coraza-kubernetes-operator/}"
CORAZA_CHART_REPO_NAME="${CORAZA_CHART_REPO_NAME:-coraza-kubernetes-operator}"
CORAZA_CHART="${CORAZA_CHART:-coraza-kubernetes-operator/coraza-kubernetes-operator}"
# Empty means "newest in the repo index". Pin it for a reportable run: the
# operator version is part of what the number describes.
CORAZA_CHART_VERSION="${CORAZA_CHART_VERSION:-}"
CORAZA_NAMESPACE="${CORAZA_NAMESPACE:-coraza-system}"
CORAZA_RELEASE="${CORAZA_RELEASE:-coraza-kubernetes-operator}"

# --- logging ----------------------------------------------------------------
if [[ -t 1 ]]; then
  _B="\033[1;34m"; _G="\033[1;32m"; _Y="\033[1;33m"; _R="\033[1;31m"; _X="\033[0m"
else _B=""; _G=""; _Y=""; _R=""; _X=""; fi
log()  { echo -e "${_B}==>${_X} $*"; }
ok()   { echo -e "${_G}✓${_X} $*"; }
warn() { echo -e "${_Y}!${_X} $*" >&2; }
err()  { echo -e "${_R}✗${_X} $*" >&2; }

require_cmd() { command -v "$1" >/dev/null 2>&1 || { err "missing command: $1"; exit 1; }; }

preflight() {
  require_cmd "${CLI}"
  "${CLI}" cluster-info >/dev/null 2>&1 || { err "cannot reach cluster via '${CLI}'"; exit 1; }
}

# True when the cluster serves the OpenShift route API. Cheaper and more
# reliable than reading the version: 'oc' talks to plain Kubernetes too, so the
# CLI in use says nothing about what is on the other end.
cluster_is_openshift() {
  "${CLI}" api-resources --api-group=route.openshift.io 2>/dev/null | grep -q "routes"
}

# PLATFORM drives GATEWAY_CLASS and CLI, so guessing it wrong sends every later
# script at a gateway class that does not exist. Fail here instead.
require_platform_match() {
  if cluster_is_openshift && [[ "${PLATFORM}" != "openshift" ]]; then
    err "cluster is OpenShift but PLATFORM='${PLATFORM}'. Run: export PLATFORM=openshift"
    exit 1
  fi
  if ! cluster_is_openshift && [[ "${PLATFORM}" == "openshift" ]]; then
    err "PLATFORM=openshift but the cluster has no route.openshift.io API. Unset PLATFORM."
    exit 1
  fi
}

has_crd() { "${CLI}" get crd "$1" >/dev/null 2>&1; }

# Exec a command in the load generator pod.
loadgen_exec() {
  "${CLI}" exec -n "${NAMESPACE}" "deploy/${LOADGEN_NAME}" -- "$@"
}
