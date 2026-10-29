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
# Unset means "ask the cluster". PLATFORM decides both the CLI and the gateway
# class, and defaulting it blindly to kubernetes on an OpenShift cluster aimed
# setup.sh at a GatewayClass that does not exist there — which surfaced as a
# hang on the Gateway readiness wait, not an error. Set it explicitly to
# override (e.g. PLATFORM=kubernetes on OpenShift when Istio was installed by
# hand rather than by the cluster ingress operator).
PLATFORM_DETECTED=false
if [[ -z "${PLATFORM:-}" ]]; then
  _probe="$(command -v oc || command -v kubectl || true)"
  if [[ -n "${_probe}" ]] && \
     "${_probe}" api-resources --api-group=route.openshift.io 2>/dev/null | grep -q "routes"; then
    PLATFORM=openshift
  fi
  PLATFORM="${PLATFORM:-kubernetes}"
  PLATFORM_DETECTED=true
  unset _probe
fi
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

# Pod sizing. The defaults deliberately over-provision: the backend must never
# be the bottleneck, or the number describes the backend and not the WAF.
# Lower them only to exercise the harness on a cluster that cannot fit the
# defaults (CRC, kind). Any run made with reduced sizing is a smoke test, not a
# measurement — it is the throttling these values exist to avoid.
BACKEND_REPLICAS="${BACKEND_REPLICAS:-3}"
BACKEND_CPU_REQUEST="${BACKEND_CPU_REQUEST:-1}"
BACKEND_CPU_LIMIT="${BACKEND_CPU_LIMIT:-2}"
BACKEND_MEM_REQUEST="${BACKEND_MEM_REQUEST:-256Mi}"
BACKEND_MEM_LIMIT="${BACKEND_MEM_LIMIT:-512Mi}"
LOADGEN_CPU_REQUEST="${LOADGEN_CPU_REQUEST:-2}"
LOADGEN_CPU_LIMIT="${LOADGEN_CPU_LIMIT:-4}"
LOADGEN_MEM_REQUEST="${LOADGEN_MEM_REQUEST:-512Mi}"
LOADGEN_MEM_LIMIT="${LOADGEN_MEM_LIMIT:-1Gi}"

# WAF resource names.
ENGINE_NAME="${ENGINE_NAME:-perf-engine}"
RULESET_NAME="${RULESET_NAME:-perf-ruleset}"

# Observability (optional metric collection via collect.sh).
PROM_NAMESPACE="${PROM_NAMESPACE:-monitoring}"
PROM_SVC="${PROM_SVC:-prometheus-k8s}"
PROM_PORT="${PROM_PORT:-9090}"

WAIT_TIMEOUT="${WAIT_TIMEOUT:-180s}"
# How long waf.sh waits for the operator to withdraw the WasmPlugin after the
# Engine is deleted. Separate from WAIT_TIMEOUT because this one gates a
# measurement rather than a provisioning step: it should fail fast and loudly
# rather than sit for three minutes.
WASM_WAIT_TIMEOUT="${WASM_WAIT_TIMEOUT:-60}"

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
# Operator image. Empty means "whatever the chart defaults to", which is the
# ghcr.io release image for the chart version.
#
# Those release images are linux/amd64 only — every tag through v0.5.0 is a
# single-platform index — so on an arm64 cluster (CRC on Apple Silicon) the pod
# fails with "no image found in image index for architecture arm64". Two ways
# out, and both need CORAZA_CRD_DIR with them, because neither image is the
# chart's any more:
#
#   - The Konflux stream below publishes linux/amd64 + linux/arm64. It is a
#     staging registry: tags are commit SHAs, there is no 'latest', and builds
#     are garbage-collected. Fine for getting a cluster working, not something
#     to pin a reported number to.
#   - Build the operator yourself. See docs/prerequisites.md, "Architectures".
#
# CORAZA_IMAGE_ARM64_HINT is only ever printed, never applied: which image you
# run is a decision about what the number describes, so the script names the
# option and leaves the choice.
CORAZA_IMAGE_REPO="${CORAZA_IMAGE_REPO:-}"
CORAZA_IMAGE_TAG="${CORAZA_IMAGE_TAG:-}"
CORAZA_IMAGE_ARM64_HINT="${CORAZA_IMAGE_ARM64_HINT:-quay.io/redhat-user-workloads-stage/waf-tenant/waf-0-7/waf-operator}"
# Where install-operator.sh reads the CRDs from. Empty means "the chart's own
# crds/", which is right whenever the image is the chart's too.
#
# It is not right for a locally built image. The chart's CRDs are pinned to the
# chart version, the image is not, and the pair has to match: a build newer
# than the chart needs CRD fields the chart has never heard of. Published
# chart 0.5.0 ships rulesources and ruledata with no status subresource, so an
# operator built after that writes RuleSource status into an endpoint the API
# server does not serve, and every patch comes back "not found" — naming the
# object, not the schema. The RuleSet then waits on a validation that can never
# arrive and waf.sh times out on 'oc wait ruleset --for=condition=Ready'.
#
# Point this at config/crd/bases in the same checkout the image was built from,
# always alongside CORAZA_IMAGE_REPO. See docs/prerequisites.md.
CORAZA_CRD_DIR="${CORAZA_CRD_DIR:-}"

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

# Only an explicitly set PLATFORM can disagree with the cluster; a detected one
# came from the cluster in the first place. Warn rather than fail: overriding
# is legitimate (hand-installed Istio on OpenShift), getting it wrong by
# accident is not, and the two look identical from here.
require_platform_match() {
  "${PLATFORM_DETECTED}" && return 0
  if cluster_is_openshift && [[ "${PLATFORM}" != "openshift" ]]; then
    warn "PLATFORM='${PLATFORM}' but the cluster is OpenShift — expecting GatewayClass '${GATEWAY_CLASS}'."
    warn "Unset PLATFORM to let it be detected, unless you installed Istio yourself."
  fi
  if ! cluster_is_openshift && [[ "${PLATFORM}" == "openshift" ]]; then
    err "PLATFORM=openshift but the cluster has no route.openshift.io API."
    exit 1
  fi
}

has_crd() { "${CLI}" get crd "$1" >/dev/null 2>&1; }

# Space-separated names of the WasmPlugins in the test namespace, which is the
# control-plane view of whether Envoy is running the WAF filter. The operator
# applies one per Engine via SSA into the gateway's own namespace, and that
# namespace belongs to this harness, so anything listed here is the WAF under
# test. No CRD means Istio cannot load a WASM filter at all, so report none.
# Deliberately no '|| true' on the query: a failed lookup must surface as a
# non-zero exit ("cannot tell"), never as an empty list ("nothing attached").
wasmplugin_names() {
  has_crd wasmplugins.extensions.istio.io || return 0
  "${CLI}" get wasmplugin -n "${NAMESPACE}" \
    -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}'
}

# Block until no WasmPlugin is left in the namespace.
#   0 = gone, 1 = still there at the deadline, 2 = could not tell.
# Deleting the Engine only tells the operator to withdraw the filter: the
# WasmPlugin outlives the Engine by however long reconciliation takes, and
# Envoy keeps running the filter until istiod pushes the removal. A baseline
# measured inside that gap folds WAF cost into the number every later delta is
# subtracted from, which shrinks the reported overhead while looking valid.
wait_wasmplugin_absent() {
  local timeout="${1:-${WASM_WAIT_TIMEOUT}}" deadline names
  deadline=$(( $(date +%s) + timeout ))
  while :; do
    names="$(wasmplugin_names)" || return 2
    [[ -z "${names// /}" ]] && return 0
    (( $(date +%s) >= deadline )) && return 1
    sleep 2
  done
}

# Exec a command in the load generator pod.
loadgen_exec() {
  "${CLI}" exec -n "${NAMESPACE}" "deploy/${LOADGEN_NAME}" -- "$@"
}
