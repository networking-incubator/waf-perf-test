# Prerequisites

What the cluster needs before `scripts/setup.sh`, and the scripts that install
it. Everything here is a **one-time cluster change**, not part of a run — see
[When not to run these](#when-not-to-run-these).

```bash
scripts/prereqs/check.sh           # what is missing, in about two seconds
scripts/prereqs/install-all.sh     # install it, then re-check
```

`install-all.sh` is the default route and needs no arguments or environment:
it detects the platform and takes the path that platform expects. It is
re-runnable — each step is a no-op when its piece is already there.

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

## PLATFORM, and when to set it

`lib.sh` derives both the CLI and the gateway class from it:

| `PLATFORM` | CLI | `GATEWAY_CLASS` |
|---|---|---|
| `kubernetes` | `kubectl` | `istio` |
| `openshift` | `oc` | `openshift-default` |

Leave it unset and it is detected, by asking the cluster for the
`route.openshift.io` API — every script does this, not just the prereq ones.
Each prints which platform it is using and whether that was detected or taken
from the variable.

Set it only to override a correct detection, which in practice means one case:
Istio installed by hand on OpenShift rather than by the ingress operator, where
the gateway class is `istio` on an OpenShift cluster. Overriding earns a
warning, since an accidental override and a deliberate one look identical from
inside a script.

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

### Architectures

**The published operator image is `linux/amd64` only.** On an arm64 cluster —
CRC on Apple Silicon, say — the pod never starts:

```
no image found in image index for architecture "arm64", variant "v8", OS "linux"
```

`install-operator.sh` checks the node architecture and stops before the ten
minute `--wait` rather than letting it end in `ImagePullBackOff`. Build the
operator for your architecture from its repo and point the harness at it:

```bash
cd <coraza-kubernetes-operator>
docker build --platform linux/arm64 -t localhost/coraza-kubernetes-operator:dev .

# CRC has no registry you can push to by default; load into the VM's
# container storage, which CRI-O shares with podman:
docker save localhost/coraza-kubernetes-operator:dev -o /tmp/op.tar
scp -i ~/.crc/machines/crc/id_ed25519 -P 2222 /tmp/op.tar core@127.0.0.1:/tmp/
ssh -i ~/.crc/machines/crc/id_ed25519 -p 2222 core@127.0.0.1 'sudo podman load -i /tmp/op.tar'

CORAZA_IMAGE_REPO=localhost/coraza-kubernetes-operator CORAZA_IMAGE_TAG=dev \
  scripts/prereqs/install-operator.sh
```

The `localhost/` prefix matters: it tells CRI-O the image is already in local
storage, and the chart's default `pullPolicy: IfNotPresent` then leaves it
alone.

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
