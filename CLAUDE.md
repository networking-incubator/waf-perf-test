# CLAUDE.md

Guidance for Claude Code (claude.ai/code) when working in this repository.

## What this repo is

A performance-testing harness for the [Coraza Kubernetes Operator](https://github.com/networking-incubator/coraza-kubernetes-operator). It measures what the WAF actually costs: the `coraza-proxy-wasm` module running inside the Envoy proxy of a Gateway pod, driven by fortio from inside the cluster.

It is a test harness, not a product. Nothing here is deployed; there is no Go code, no build, and no CI. The work is bash, Python, and Kubernetes manifests.

**The number this harness produces is never an absolute latency.** It is the delta against a WAF-off baseline captured in the same session. Absolute latency is a property of the cluster it ran on and does not travel.

## The guardrails

These are not style preferences. Violating one does not make a run slightly worse; it makes the number wrong while still looking plausible. `README.md` explains the reasoning behind each in [Methodology](README.md#methodology) — read it before you decide to deviate.

1. **Capture the WAF-off baseline in the same session, before any WAF-on run.** `scripts/suite.sh` does this for you. Report the delta per percentile, never an absolute.
2. **Change one axis per run.** The three axes are load intensity, request shape, and ruleset size. Pin the other two.
3. **Wait out the settle window after toggling the WAF.** `suite.sh` waits 25 seconds; `run-comprehensive-tests.sh` waits 30. Never measure inside it.
4. **Let the warm-up be discarded.** `scripts/run.sh` throws away a 10-second run before the measured one.
5. **Repeat at least three times per data point** and report the median with its spread. None of the scripts loop, so this is on you: invoke the suite again. One run is noise.
6. **Confirm the filter actually ran.** A bypassed WAF produces a fast, clean, meaningless number.
7. **Prefer p95 and p99. Never headline the average.**

## When to throw a run away

A run is valid only when all of these hold, per [Validity criteria](README.md#validity-criteria):

- `error_pct` is 0, except on `attack-*` profiles where 403 is expected and counted as `blocked_pct`.
- `ActualQPS` is within about 5% of the requested rate.
- The shape probe returned the profile's `EXPECT_STATUS`.
- No plugin reload happened inside the measurement window.

An `ActualQPS` shortfall is itself a finding — the system could not hold the offered load — but it invalidates the latency comparison for that cell, because the percentiles then describe a lighter workload than the baseline they are compared against.

## Entry points

All scripts resolve their own paths, so they work when invoked from anywhere.

```bash
scripts/setup.sh                      # provision namespace, backend, loadgen, Gateway, payloads
scripts/waf.sh on <minimal|medium|crs>  # or: off | status
scripts/suite.sh <scenario-file> [rulesets...]   # canonical: baseline then one run per ruleset
scripts/run.sh <scenario-file> [tag]  # one measured run with validity probes
scripts/collect.sh <start> <end> [tag]  # pull Prometheus metrics for a window
scripts/teardown.sh                   # delete the namespace; results are kept
```

Reporting needs no cluster:

```bash
pip install -r requirements.txt
python3 scripts/report.py --scenario <name>   # delta vs baseline, medians across repeats
python3 generate-report.py                    # the full 3x4 matrix
```

`scripts/report.py` is the one to report from. It computes the delta against the baseline across repeats. Use `generate-report.py` for a matrix overview only.

For a guided run, the bundled skill at `.claude/skills/perf-test/SKILL.md` carries the correct ordering and the delta analysis. It defers to this file where the two disagree.

## Prerequisites this harness does not install

- A Kubernetes v1.32+ or OpenShift v4.20+ cluster with Istio and the Gateway API CRDs.
- The Coraza Kubernetes Operator, already installed. This harness never installs it.
- Local tools: `kubectl` or `oc`, `envsubst`, `python3`, `curl`.
- For metrics collection, a reachable Prometheus with the operator's ServiceMonitor and PodMonitor enabled.
- Dedicated node pools and guaranteed QoS for the load generator, Gateway, and backend. Without them you are measuring CPU throttling.

## Defects that will mislead you

Carried over from the harness's previous home and deliberately not fixed, so the port stays faithful. [Known limitations](README.md#known-limitations) has the full list with line references.

- **Every generated report claims the author's cluster.** `generate-report.py` and `templates/report-template.html` hardcode OpenShift 4.22.18, Istio v1.27.5, operator v0.5.0 and Fortio 1.76.0 as literals. Nothing reads them off the live cluster. Correct them by hand before circulating any report.
- **The matrix is one repeat per cell.** `run-comprehensive-tests.sh` runs each combination once, which the methodology says is not reportable. Its output is indicative only.
- **The load generator image is unpinned.** Both `lib.sh` and `manifests/loadgen.yaml` pull `fortio/fortio:latest`, so runs weeks apart may not share a load generator.
- **The scenario name is hardcoded twice.** `generate-report.py` and `analyze-results.py` each carry their own `fixed-500qps` glob.

## Conventions

- Shell scripts are `set -euo pipefail` and source `lib.sh` for shared config. Every tunable is an environment variable with a default in `lib.sh`; add new ones there rather than inline.
- Comments in these scripts frequently record why a past approach failed. Preserve them when editing.
- `results/` is ignored. Fixture data for exercising the report generators lives in `testdata/sample-results/` and was measured on another cluster; no number in it is reportable here. Never copy it into `results/`: the per-scenario report medians every run it finds for a tag, so a fixture left there silently averages another cluster into the delta.
- Do not quote figures from `README.md` or any previous run. Regenerate the report and read the current data.
