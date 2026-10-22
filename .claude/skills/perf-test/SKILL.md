---
name: perf-test
description: Run Coraza WAF performance tests — baseline-vs-WAF latency/throughput comparison — using the harness in this repository. Use for "perf test", "benchmark the WAF", "WAF latency/overhead", "load test the gateway", "perf regression".
user_invocable: true
allowed_tools: Bash, Read, Grep, Glob
---

# Coraza WAF Performance Testing

Drive this repository's performance-testing harness to measure the WAF the way
it actually runs: as the `coraza-proxy-wasm` module **inside the Envoy proxy of
the Gateway pod**, with load generated **in-cluster** by fortio.

**You orchestrate the existing scripts and enforce the methodology — you do NOT
reimplement port-forwarding, fortio invocation, or cleanup.** The scripts under
`scripts/` are the source of truth; this skill adds the correct ordering, the
guardrails, and the delta analysis.

Read `README.md` (architecture, the three axes, methodology, tiers, scenarios,
known limitations) if you need background — it owns the *why* behind every rule
below. `CLAUDE.md` at the repo root is this repository's agent contract and is
authoritative where it and this skill disagree. All scripts `cd` to the repo
root themselves, so they can be invoked by path from anywhere.

## Prerequisites (verify first)

- The **operator is already installed** — this harness does not install it, and
  there is no `config/` tree or Helm chart in this repo. It comes from
  [`networking-incubator/coraza-kubernetes-operator`](https://github.com/networking-incubator/coraza-kubernetes-operator);
  its [DEVELOPMENT.md](https://github.com/networking-incubator/coraza-kubernetes-operator/blob/main/DEVELOPMENT.md)
  covers installation and the cluster prerequisites.
- A reachable cluster with Istio + Gateway API CRDs (`kubectl` context set).
- Local tools: `kubectl` (or `oc`), `envsubst`, `python3`, `curl`.
- For `collect`/metrics: Prometheus reachable with the operator's ServiceMonitor
  (`:8443`) and PodMonitor (`:15090`) enabled. Both ship in the operator's Helm
  chart (`charts/coraza-kubernetes-operator` in that repo) and are **disabled by
  default** — install it with `metrics.serviceMonitor.enabled=true` and
  `metrics.podMonitor.enabled=true`, or skip the metrics mode.

If the user hasn't provisioned the target yet, run **setup** before any run.

## Modes

Pick the mode from the user's request (or the `args`). Modes map to scripts:

| Mode (`args`) | What it does | Command |
|---|---|---|
| `setup` | Provision ns + backend + loadgen + gateway (WAF still off) | `scripts/setup.sh` |
| `suite <scenario> [rulesets…]` | **Canonical run:** WAF-off (B0) then WAF-on per ruleset | `LOAD_PROFILE=… scripts/suite.sh <scenario-file> <rulesets…>` |
| `run <scenario> <tag>` | One measured run with validity probes | `LOAD_PROFILE=… scripts/run.sh <scenario-file> <tag>` |
| `waf on\|off\|status` | Toggle the WAF manually | `scripts/waf.sh on medium` |
| `collect <start> <end> <tag>` | Pull Prometheus metrics for a window | `scripts/collect.sh <start> <end> <tag>` |
| `analyze [scenario]` | Build the self-contained HTML report + WAF-cost delta from `results/` | `scripts/report.py [--scenario NAME]` (no cluster needed) |
| `matrix` | **INDICATIVE ONLY** — 3 profiles × 4 rulesets at `fixed-500qps`, 12 runs, then the matrix report | `./run-comprehensive-tests.sh` |
| `matrix-report` | **INDICATIVE ONLY** — rebuild the matrix HTML from `results/` | `python3 generate-report.py` (no cluster needed) |
| `matrix-text` | Percentile / throughput / consistency tables for the matrix, printed to stdout | `python3 analyze-results.py` (no cluster needed) |
| `teardown` | Delete the test namespace (results kept) | `scripts/teardown.sh` |
| `crs` | Generate an OWASP CoreRuleSet ruleset for a run | see **Larger rulesets** below |

### Why the matrix entry points are INDICATIVE ONLY

`run-comprehensive-tests.sh`, `generate-report.py` and `analyze-results.py` are
the fastest way to see all twelve cells at once, and their output is **not
reportable**. Say so whenever you route a user to them. Both defects are
recorded in README → *Known limitations*; neither is fixed:

- **One repeat per cell.** `run-comprehensive-tests.sh` runs each combination
  once (it says so in its own banner); the methodology below wants ≥3 and a
  median with spread. `generate-report.py` and `analyze-results.py` both pick
  the *latest* result per `(profile, ruleset)` cell, so they report a single
  run, never a median.
- **Every generated report claims the author's cluster.**
  `generate-report.py` bakes `OpenShift 4.22.18`, Istio `v1.27.5`, operator
  `v0.5.0`, `Fortio 1.76.0` and `500 req/s` in as literals (lines 1226–1230),
  and `templates/report-template.html` repeats the operator version (line 908),
  Istio (line 924) and the platform (lines 884, 920). Nothing reads those facts
  off the cluster. Correct them by hand before circulating a number.
- Both analysis scripts also hardcode the `fixed-500qps` scenario in their own
  copy of `find_latest_result()`, so they silently find nothing for any other
  scenario. `analyze-results.py` additionally hardcodes its ruleset labels
  (it prints `minimal` as 2 rules; the manifest has 1).

For anything you intend to report, use `suite.sh` ≥3× and `scripts/report.py`,
which computes the delta vs B0 across repeats.

## Choosing what to run — the user must pick

A run is **three independent axes**, and they compose into a large matrix:

```
scenario (how hard)   ×   load profile (request shape)   ×   rulesets (which rules)
fixed-500qps              args-light                         minimal, medium, crs
low-rate-200qps           args-heavy / json-100kb / ...      (waf-off baseline is always added)
max-throughput            attack-sqli / attack-keyword
soak                      baseline-get / multipart / ...
```

**Never pick for the user and never fall back to a silent default.** When the
request is just "run a perf test" (or anything that doesn't pin all three axes),
**ask first** with `AskUserQuestion`. Offer the presets below that best fit their
wording — the tool allows at most 4 options.

If they choose **"Other"**, switch to the **guided composition** flow further
down: scenario → load profile → rulesets, one question per axis. Never ask them
to type a raw command.

State the run count and rough wall-clock in the option description; these runs
cost real time and the user should choose with that in view.

### Presets

| Preset | Answers | scenario × profile × rulesets | Runs | ~Time |
|---|---|---|---|---|
| **quick** | Is the harness healthy? Rough overhead floor. *Not for reporting — 1 repeat.* | `fixed-500qps` × `baseline-get` × `minimal` | 2 | ~6 min |
| **standard** | What does the WAF cost on typical traffic? **Recommend this when unsure.** | `fixed-500qps` × `args-light` × `minimal, medium, crs` | 12 | ~35 min |
| **args-scaling** | How much does per-argument evaluation cost? | `fixed-500qps` × `args-heavy` × `crs` | 6 | ~17 min |
| **body-cost** | What do large parsed bodies cost? | `low-rate-200qps` × `json-100kb` × `medium, crs` | 9 | ~25 min |
| **blocking** | What does the deny path cost? | `fixed-500qps` × `attack-sqli` × `crs` | 6 | ~17 min |
| **saturation** | Max RPS — where is the knee? | `max-throughput` × `baseline-get` × `minimal, crs` | 9 | ~16 min |
| **soak** | Stability over an hour (leaks, GC, drift). *1 repeat.* | `soak` × `args-light` × `crs` | 2 | ~2 h |
| **matrix** | All 3 matrix profiles × 4 rulesets in one go. *1 repeat per cell — INDICATIVE ONLY.* | `fixed-500qps` × `baseline-get, args-heavy, headers-heavy` × `minimal, medium, crs` | 12 | ~45–55 min |
| **custom** | Anything else — user picks one value per axis. | see below | — | — |

Run counts already include the **3 repeats** the methodology requires (except
`quick`, `soak` and `matrix`, which are 1 — say so when offering them).

### Preset commands

Each is one suite invocation; repeat it 3× unless the table says otherwise.

```bash
# quick  (1 repeat only)
LOAD_PROFILE=baseline-get scripts/suite.sh scenarios/fixed-500qps.env minimal

# standard
LOAD_PROFILE=args-light   scripts/suite.sh scenarios/fixed-500qps.env minimal medium crs

# args-scaling
LOAD_PROFILE=args-heavy   scripts/suite.sh scenarios/fixed-500qps.env crs

# body-cost
LOAD_PROFILE=json-100kb   scripts/suite.sh scenarios/low-rate-200qps.env medium crs

# blocking
LOAD_PROFILE=attack-sqli  scripts/suite.sh scenarios/fixed-500qps.env crs

# saturation
LOAD_PROFILE=baseline-get scripts/suite.sh scenarios/max-throughput.env minimal crs

# soak  (1 repeat only)
LOAD_PROFILE=args-light   scripts/suite.sh scenarios/soak.env crs

# matrix  (1 repeat per cell — INDICATIVE ONLY, see above)
./run-comprehensive-tests.sh
```

### Custom composition — guided, one axis at a time

When the user picks **"Other"** on the preset question, or asks for a
combination no preset covers, **do not ask them to type a command**. Walk the
three axes in order with a separate `AskUserQuestion` per step, carrying the
earlier answers forward and showing them in each prompt.

**Step 1 — scenario (how hard to push).** Single select, all four fit:

| Option | Rate / duration |
|---|---|
| `fixed-500qps` | 500 qps, 120 s — the primary latency KPI |
| `low-rate-200qps` | 200 qps, 120 s — for expensive shapes (big bodies, multipart) |
| `max-throughput` | unthrottled, 60 s — find the saturation knee |
| `soak` | 300 qps, 1 h — leaks, GC, drift |

**Step 2 — load profile (request shape).** Twelve profiles exceed the 4-option
limit, so ask the **family** first, then the profile within it.

*Step 2a — family:*

| Option | Covers |
|---|---|
| Plain GET | no body; varies args and headers |
| POST, parsed body | WAF parses the body (JSON / form / multipart) |
| POST, opaque bytes | body transferred but not parsed |
| Blocking / attack | measures the deny path |

*Step 2b — profile (each family fits one question):*

| Family | Options |
|---|---|
| Plain GET | `baseline-get`, `args-light`, `args-heavy`, `headers-heavy` |
| POST, parsed body | `json-1kb`, `json-100kb`, `form-urlencoded`, `multipart` |
| POST, opaque bytes | `body-1kb`, `body-100kb` |
| Blocking / attack | `attack-sqli`, `attack-keyword` |

**Step 3 — rulesets.** Use `multiSelect: true` over the rulesets; `waf-off` is
always run first as the baseline and is not an option.

**Constrain this step by the profile chosen in step 2** — offer only rulesets
that actually block it, rather than letting the shape probe abort the run:

| Profile chosen | Offer |
|---|---|
| `attack-sqli` | `crs` only |
| `attack-keyword` | `minimal`, `medium` only |
| anything else | `minimal`, `medium`, `crs` |

**Step 4 — confirm, then run.** Echo the resolved command with the run count and
estimated wall-clock before starting:

```bash
LOAD_PROFILE=<profile> scripts/suite.sh scenarios/<scenario>.env <ruleset…>
```

Estimate with: `runs = (number of rulesets + 1) × repeats`, and
`per-run ≈ WARMUP + DURATION + SETTLE + ~10s`. Default `WARMUP=10s`,
`SETTLE=25s`, repeats = 3 (so `fixed-500qps` ≈ 165 s per run).

Then run it the agreed number of times, finish with **analyze**, and report the
delta vs B0 **with the spread** across repeats.

Full profile details: `manifests/load-profiles/README.md`.

## Methodology — non-negotiable guardrails

`suite.sh` already encodes most of this; **preserve it, and enforce the rest.**
README → *Methodology* explains why each rule exists; these are the numbers.

1. **B0 (WAF off) first, same session.** Always capture the WAF-off baseline
   before any WAF-on run. `suite.sh` does this automatically; if you drive
   `run.sh` manually, run `waf.sh off` → measure `waf-off` **before** any
   `waf-*` run. Never report an absolute — report the **delta vs. B0**.
2. **Settle after toggling.** After `waf.sh on/off`, wait for Istio to apply or
   remove the WasmPlugin, plus one poll interval (~15s) if the cache is enabled.
   `suite.sh` uses `SETTLE=25s`; `run-comprehensive-tests.sh` uses 30s. Don't
   measure inside the settle window.
3. **Validity probe.** When `LOAD_PROFILE` is set, `run.sh` sends one request of
   the profile's exact shape and compares it to `EXPECT_STATUS` (default 200;
   blocking profiles declare 403), aborting in ~1s rather than measuring
   rejected traffic. `suite.sh` forces `EXPECT_STATUS=200` on the WAF-off
   baseline. A run where the WAF silently wasn't active is **rejected**, not
   silently wrong.
4. **Warm-up is discarded** (`WARMUP`, default 10s) — `run.sh` handles it.
5. **Pin the rule version.** No RuleSet edits during a latency run (except the
   rule-churn scenario). A mid-run plugin reload invalidates the window.
6. **Repeat ≥3× per data point.** The scripts do **not** loop — you must run the
   suite/scenario **at least 3 times** and report the **median + spread**. One
   run is noise.
7. **Reject bad runs.** A run is valid only when `error_pct` is 0 (except
   `attack-*` profiles, where 403 is expected and counted separately as
   `blocked_pct`), `ActualQPS` is within ~5% of the requested rate, the shape
   probe returned `EXPECT_STATUS`, and no plugin reload occurred inside the
   window. Also discard runs with node CPU throttling. An `ActualQPS` shortfall
   is itself a throughput result — report it as one, and re-run the latency cell
   at a rate the system can hold.
8. **Report the gap correctly** (see Analyze): per percentile, like-for-like,
   `added pN = pN(WAF on) − pN(WAF off)`, in **ms** and **% = (on−off)/off**.
9. **Trust a gap only when it exceeds run-to-run variance.** A delta smaller
   than the WAF-off spread is noise, not signal.

## Scenarios

Files live in `scenarios/` (sourced env fragments):

| File | Purpose |
|---|---|
| `fixed-500qps.env` | Latency at a fixed sub-saturation rate (primary latency KPI) |
| `low-rate-200qps.env` | Reduced rate for expensive shapes (large bodies, multipart) |
| `max-throughput.env` | Push max QPS to find the knee (saturation RPS) |
| `soak.env` | Long-duration stability (leaks/GC) |
| `fixed-500qps-short.env` | 60s variant of the primary scenario; **not** what `run-comprehensive-tests.sh` uses |

Scenarios set **only** QPS/duration/connections. Request shape lives in
**load profiles** (`manifests/load-profiles/`), selected with `LOAD_PROFILE`:
`baseline-get`, `args-light`, `args-heavy`, `headers-heavy`, `form-urlencoded`,
`json-1kb`, `json-100kb`, `multipart`, `body-1kb`, `body-100kb`, `attack-sqli`
(CRS only), `attack-keyword` (minimal/medium only). Body-size cost =
`body-*`/`json-*` profiles; blocking-path cost = `attack-*` profiles, which
declare `EXPECT_STATUS=403` and are validated automatically. Results are filed
under `<scenario>+<profile>`.

## Rulesets

All three are committed under `manifests/rulesets/` and resolve by bare name —
`waf.sh on <name>`, or pass a path to any other YAML.

- `minimal` (1 rule) — WASM-filter overhead floor.
- `medium` (30 rules) — typical hand-written policy.
- `crs` (563 rules) — OWASP CoreRuleSet 4.7.0; the dominant latency driver and
  the most important data point.

### Regenerating CRS

Only needed to bump the CRS version. `kubectl coraza` is built from the operator
repo, not this one — download a `kubectl-coraza` binary from the
[operator's releases](https://github.com/networking-incubator/coraza-kubernetes-operator/releases)
(cut by its `release.kubectl-plugin` target) and put it on your `PATH` first.
Then, from this repo's root:

```bash
curl -sL https://github.com/coreruleset/coreruleset/archive/refs/tags/v4.7.0.tar.gz | tar -xz -C /tmp
kubectl coraza generate coreruleset \
  --rules-dir /tmp/coreruleset-4.7.0/rules --version 4.7.0 \
  --ruleset-name perf-ruleset \
  --ignore-unsupported-rules wasm \
  --ignore-rules 920420 \
  > manifests/rulesets/crs.yaml
```

`--rules-dir` and `--version` are required; the command errors without them.
Two things are hand-added to the generated file and must be re-added after
regenerating — both explained in its header comment:

- the `skip-unsupported-rules-check` annotation on the RuleSet (CRS 980170)
- `--ignore-rules 920420`: under coraza-proxy-wasm that rule rejects **every**
  request carrying a `Content-Type`, so all POST traffic 403s. It fires even
  when the content type is in the allowlist.

## Analyze — the self-contained HTML report + WAF-cost delta

`scripts/report.py` is the primary analyzer. It reads `results/` (fortio `*.json`
grouped by tag; `waf-off` = B0), takes the **median across repeats**, computes
the delta vs B0 per percentile, folds in the server-side summary from any
`metrics__*.jsonl` (`collect.sh`), and writes a **self-contained**
`dashboard.html` — the durable per-run artifact. Needs **no cluster** and **no
live Grafana/Prometheus** to view. `suite.sh` runs it automatically at the end
of a suite, writing `results/<scenario>+<profile>.html`.

```bash
scripts/report.py                 # single scenario in results/
scripts/report.py --scenario fixed-500qps+args-light --out results/fixed-500qps+args-light.html
```

`generate-report.py` (matrix HTML) and `analyze-results.py` (matrix text tables)
read the same `results/` directory but take the latest run per cell, not a
median, and carry hardcoded cluster facts — **INDICATIVE ONLY**, see *Modes*.

Cross-run comparison (e.g. runs a week apart) is **report-to-report** against the
committed baseline — not on a live dashboard. For a quick textual delta
without the HTML:

1. `grep -H . results/<scenario>__*.summary.txt` (has `p50_ms…p99.9_ms`, `error_pct`).
2. Per percentile: `added = pX(waf-*) − pX(waf-off)` (median of repeats), in ms and %.
3. Flag elevated `error_pct`; warn if the gap is **smaller than waf-off's run-to-run
   variance** (noise, not signal). Prefer p95/p99; never headline the average.

## Configuration knobs (env vars; defaults in `lib.sh`)

| Var | Default | Meaning |
|---|---|---|
| `PLATFORM` | `kubernetes` | `kubernetes` or `openshift` (CLI + GatewayClass) |
| `NAMESPACE` | `waf-perf` | Test namespace |
| `GATEWAY_NAME` | `perf-gateway` | Gateway name |
| `RULESET_NAME` | `perf-ruleset` | RuleSet name the Engine attaches (match for CRS) |
| `FAILURE_POLICY` | `fail` | Engine failure policy (`fail`/`allow`) |
| `WARMUP` | `10s` | Discarded warm-up per run |
| `SETTLE` | `25s` | Post-toggle wait for WASM poll (suite.sh) |
| `COLLECT` | `false` | suite.sh also pulls Prometheus metrics |
| `PROM_NAMESPACE`/`PROM_SVC`/`PROM_PORT` | `monitoring`/`prometheus-k8s`/`9090` | Prometheus location |

Full table, including `POLL_CACHE`, `EXPECT_*`, `TARGET_URL` and
`LOADGEN_IMAGE`: README → *Configuration knobs*.

To also gather metrics during a suite: `COLLECT=true scripts/suite.sh …`.

## Gotchas

- **Don't measure inside the settle window** — the WASM plugin polls every ~15s;
  a fresh toggle isn't live yet.
- **A `coraza_waf_plugin_loads_total` bump mid-window invalidates the run.**
- **Request shape comes from the load profile, not from flags you invent.**
  `run.sh` already plumbs `METHOD`, `REQ_PATH`, `CONTENT_TYPE`, `PAYLOAD_FILE`,
  `PAYLOAD`, `PAYLOAD_SIZE` and `HEADERS` through to fortio — PUT/PATCH and
  custom headers are supported. Add a profile rather than editing `run.sh`.
- **`PAYLOAD_FILE` paths resolve to `/payloads/...`** from the `perf-payloads`
  ConfigMap, mounted in both the loadgen pod (probes, warm-up) and the
  measured-run Job. A new body needs `gen-payloads.sh` + `setup.sh` before it
  is visible, so **run `setup` before any `json-*`/`form-urlencoded`/`multipart`
  preset** — the mount is `optional`, and `run.sh`'s pre-run ConfigMap check is
  what stops an unbuilt payload from being measured as an empty body.
- **Mixed benign/malicious ratios aren't a single fortio run** — run benign and
  attack scenarios separately.
- **Absolute latency is not portable** across clusters — only the delta vs. B0
  is. Never headline an absolute number.
- **Backend must never be the bottleneck** — it's an over-provisioned echo; if
  it saturates you're measuring the app, not the WAF.
- **Never circulate a `generate-report.py` HTML unedited** — it asserts the
  author's cluster (OpenShift/Istio/operator/Fortio versions) whatever you ran
  against.
