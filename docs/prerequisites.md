# Prerequisites

What the cluster needs before `scripts/setup.sh`, and the scripts that install
it. Everything here is a **one-time cluster change**, not part of a run — see
[When not to run these](#when-not-to-run-these).

```bash
export PLATFORM=openshift          # omit on vanilla Kubernetes
scripts/prereqs/check.sh           # what is missing, in about two seconds
scripts/prereqs/install-all.sh     # install it, then re-check
```

`install-all.sh` is re-runnable: each step is a no-op when its piece is already
there.

---

## What is required, and why

| Piece | Why the harness needs it |
|---|---|
| Gateway API CRDs | `manifests/gateway.yaml` is a `Gateway` + `HTTPRoute` |
| Istio control plane with a GatewayClass | The Gateway pod *is* the Envoy under test |
| `WasmPlugin` CRD (`extensions.istio.io`) | How `coraza-proxy-wasm` reaches that Envoy |
| Coraza Kubernetes Operator | Owns `Engine`/`RuleSet`/`RuleSource`, which `waf.sh` toggles |
| `ServiceMonitor` CRD | Optional. Only `scripts/collect.sh` uses it |

`setup.sh` checks none of this. It applies the Gateway and waits for a
`Programmed` condition that, without a GatewayClass, never arrives — so a
missing prerequisite presents as a hang, not an error. Run `check.sh` first.

---

## Set PLATFORM first

`lib.sh` derives both the CLI and the gateway class from it:

| `PLATFORM` | CLI | `GATEWAY_CLASS` |
|---|---|---|
| `kubernetes` (default) | `kubectl` | `istio` |
| `openshift` | `oc` | `openshift-default` |

Every script, not just these, needs it. Getting it wrong points `setup.sh` at a
gateway class that does not exist, so the prereq scripts refuse to run when the
value disagrees with the cluster.

---

## OpenShift

The cluster ingress operator owns Istio here. You do not install it — you
create a GatewayClass with the controller it watches, and it installs OSSM and
an Istio control plane for you:

```bash
oc apply -f - <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: openshift-default
spec:
  controllerName: openshift.io/gateway-controller/v1
EOF

oc wait --for=condition=Accepted gatewayclass/openshift-default --timeout=600s
```

That is all `scripts/prereqs/install-istio.sh` does on OpenShift, plus waiting
for the `WasmPlugin` CRD to appear — OLM resolution takes minutes, well past
the point where it looks stuck.

**Do not install Istio by hand on OpenShift.** A second control plane is not
the one the managed gateway follows, and the WAF never loads.

### Versions are the cluster's choice, not yours

The ingress operator pins them in its own deployment:

```bash
oc get deploy ingress-operator -n openshift-ingress-operator \
  -o jsonpath='{range .spec.template.spec.containers[0].env[*]}{.name}={.value}{"\n"}{end}' \
  | grep -E 'ISTIO_VERSION|GATEWAY_API_OPERATOR'
```

On OpenShift 4.22.14 that reads `servicemeshoperator3.v3.3.1` and Istio
`v1.28.5`. Read them off the cluster and put them in the report by hand —
`generate-report.py` hardcodes someone else's versions and will not correct
itself.

### Gateway API CRDs

Shipped and reconciled by the cluster. `install-gateway-api.sh` refuses to run
on OpenShift rather than fight the ingress operator.

---

## Kubernetes

```bash
scripts/prereqs/install-gateway-api.sh   # kubectl kustomize ...gateway-api/config/crd?ref=v1.4.1
scripts/prereqs/install-istio.sh         # istioctl install --set profile=minimal
```

`istioctl` is downloaded at `ISTIO_VERSION` if it is not already on PATH; if it
is, that binary's version wins and the script says so. istiod creates the
`istio` GatewayClass once the Gateway API CRDs exist, which is why the order
matters.

The profile is `minimal`, not `demo`: the demo profile adds telemetry addons
that compete for CPU with the proxy under test.

---

## The operator

Installed from the chart the operator repo's release CI publishes, so this
needs no operator checkout:

```bash
helm repo add coraza-kubernetes-operator \
  https://networking-incubator.github.io/coraza-kubernetes-operator/
helm repo update
helm upgrade --install coraza-kubernetes-operator \
  coraza-kubernetes-operator/coraza-kubernetes-operator \
  --namespace coraza-system --create-namespace
```

`scripts/prereqs/install-operator.sh` adds, on OpenShift,
`--set openshift.enabled=true --set istio.revision=openshift-gateway`. That
revision must match the control plane the ingress operator created; against the
wrong revision the operator writes a WasmPlugin no gateway proxy is watching,
and you measure a WAF that never ran — which [guardrail
6](../README.md#methodology) exists to catch.

**Pin the chart version for anything you intend to report:**

```bash
CORAZA_CHART_VERSION=0.5.0 scripts/prereqs/install-operator.sh
```

Unpinned, you get whatever is newest in the index that day, and two runs a week
apart may not share an operator.

To test operator changes you have not released, use `make deploy` from the
operator repo instead and skip this script.

---

## Beyond the CRDs

`check.sh` cannot see these, and without them you are measuring CPU throttling
rather than the WAF:

- **Dedicated node pools** for the load generator, the Gateway, and the backend.
- **Guaranteed QoS** — CPU requests equal to limits — on all three.
- **Prometheus** reachable, with the operator's ServiceMonitor and PodMonitor
  enabled, if you want `collect.sh` to return anything.

See [Environment requirements](../README.md#environment-requirements) and
[Confounders and risks](../README.md#confounders-and-risks).

---

## When not to run these

Not between a baseline and a WAF-on run. Installing or upgrading Istio restarts
the gateway proxy, which breaks the same-session comparison every number in
this harness depends on. Install first, verify with `check.sh`, then start the
session.

---

## Uninstalling

```bash
helm uninstall coraza-kubernetes-operator -n coraza-system
oc delete gatewayclass openshift-default      # OpenShift: also removes the managed Istio
istioctl uninstall --purge -y                 # Kubernetes
```

`scripts/teardown.sh` removes only the `waf-perf` namespace. It leaves all of
the above in place, which is usually what you want between sessions.
