---
title: Standalone WAF Performance Harness - Plan
type: feat
date: 2026-10-22
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-plan-bootstrap
execution: code
---

# Standalone WAF Performance Harness - Plan

**Target repo:** `waf-perf-test` (`git@github.com:networking-incubator/waf-perf-test.git`). All repo-relative paths below are relative to this repo's root.

**Source harness:** the `performance-testing` branch of a fork of `coraza-kubernetes-operator`, directory `test/performance/`, head commit `8ba846c`. Paths prefixed `source:` in this plan are relative to that directory.

---

## Goal Capsule

- **Objective:** A team member who has never seen this work can clone one repo, point it at a cluster, and come away with a defensible number for what the Coraza WAF costs on a Gateway. An agent can do the same unattended without being told the measurement rules each time.
- **Means:** Extract the existing harness from the operator fork into this repo and adapt it to stand alone (KTD1, KTD2).
- **Authority:** The source harness is authoritative for measurement behavior. This plan is authoritative for layout, packaging, and documentation.
- **Stop conditions:** Stop and ask if adapting a file would change what the harness measures, or if the source and this plan disagree about a measured value.
- **Execution profile:** Mostly file movement, packaging, and documentation. Prefer runtime smoke proof over unit coverage.
- **Finishes the work:** `ce-work` or a human implementer, landing on a branch in this repo.

---

## Product Contract

### Summary

Move the working WAF performance harness out of a fork branch of the operator repo and into this repo as its first substantive commit, adapted so nothing it ships depends on the operator source tree being next door. Add the packaging the harness never needed while it was a subdirectory: a license, a Python dependency manifest, root ignore rules, and an agent-facing `CLAUDE.md`.

### Problem Frame

The harness exists and works. It measures the `coraza-proxy-wasm` module inside the Envoy proxy of a Gateway pod, driven by fortio from inside the cluster, across three independent axes: load intensity, request shape, and ruleset size. It carries a worked-out methodology, validity gates, and two report generators. None of that needs reinventing.

What it does not have is a home. It lives on one contributor's fork branch, nested four levels down a repo whose subject is the operator rather than its performance. Someone who wants a WAF cost number has to know the fork exists, know the branch name, and clone an operator to get a benchmark. Contributions to the harness collide with operator review, and the harness is tied to a release cycle that has nothing to do with it.

This repo was created for exactly this content and is still empty. The gap between the two is a port, not a build.

### Key Decisions

- The harness sits at the repo root, not under a `test/performance/` path. The repo is the harness, so the nesting would carry no information. Governs R1, R2.
- Measurement code moves unchanged, and its known defects are recorded rather than fixed. The first commit should diff cleanly against the fork so the port itself is reviewable. Governs R3, R10.
- This repo becomes the canonical home while the fork's copy is left in place. Removing the fork's copy is someone else's call and a separate change.

### Requirements

**Port fidelity**

- R1. The harness runs from a clean clone with no path edits: scripts, scenarios, manifests, and both report generators resolve their own files relative to the repo root.
- R2. Every git-tracked file from the source harness is present, and the eleven files that are executable in the source are executable here.
- R3. What the harness measures is unchanged: no edits to fortio arguments, validity probes, warm-up or settle timing, ruleset content, or report arithmetic.

**Standalone correctness**

- R4. No document in this repo tells a reader to run something that does not exist here or next door.
- R5. A fresh `git add` cannot commit Python bytecode caches, generated payloads, or run output.
- R6. `python3 generate-report.py` succeeds on a machine that has this repo and nothing else from the operator project, after a declared dependency install.
- R7. The repo carries a license, and the vendored OWASP CoreRuleSet content carries its attribution.

**Agent operability**

- R8. An agent driving this repo learns what makes a number trustworthy before it runs anything: a WAF-off baseline captured in the same session, the settle wait after toggling the WAF, three or more repeats per data point, and the conditions that invalidate a run.
- R9. The ported agent skill routes to every entry point this repo has, and every flag value it documents is one the scripts accept.
- R10. A reader meets the harness's known defects before they are in a position to trust a number from it.

**Verifiability**

- R11. Both report generators can be exercised without a cluster.

### Success Criteria

- A reviewer can confirm the measurement code moved unchanged by diffing this repo's root against the source directory and seeing differences only in documentation, ignore rules, and the files this plan adds.
- An agent handed only this repo and a cluster produces a WAF-cost delta without being told the methodology in the prompt.

### Scope Boundaries

- Installing the operator, Istio, or Gateway API is out of scope and stays a documented prerequisite, as it already is in the source.
- Consolidating the two report generators is out of scope. They have different jobs and the source README already says which to prefer.
- CI automation and regression gating are out of scope. The source has no CI for the harness and nothing in the operator repo references it.
- Changing the three-axis model, the scenarios, the load profiles, or the rulesets is out of scope.

#### Deferred to Follow-Up Work

- Replacing the hardcoded cluster facts that both report generators bake into every report (`generate-report.py` lines 1226-1230 write `OpenShift 4.22.18`, `v1.27.5`, `v0.5.0`, `Fortio 1.76.0`, and `500 req/s` as literals; `templates/report-template.html` repeats the operator version at line 908, Istio at 924, and the platform at 884). Every report claims the author's cluster regardless of where it ran. This is the defect most worth fixing first, and it is deferred only because the confirmed scope is a faithful port.
- Removing the `fixed-500qps` hardcode that `generate-report.py` and `analyze-results.py` each carry in their own `find_latest_result()`.
- Pinning `fortio/fortio:latest` to a version, which the source README's own dependency claim of Fortio v1.76+ already contradicts.
- Deciding whether the fork's copy of the harness is deleted now that this repo exists.
- Teaching `run-comprehensive-tests.sh` to loop, so the matrix stops being a single repeat per cell.

#### Considered and not built

- A compatibility shim or symlink at `test/performance/` pointing at the root. Nothing outside the harness ever referenced that path, so the shim would serve no caller.
- Preserving the source commit history through `git subtree` or `git filter-repo`. See KTD3.
- Making `generate-report.py`'s `yaml` import optional the way `scripts/report.py` already does. See KTD5.

### Outstanding Questions

None blocking. The prerequisite under Risks must be handled before the first commit, but it needs no decision.

---

## Planning Contract

### Key Technical Decisions

- KTD1. Materialize the new repo from the source's git index, not its working tree. `git ls-files` names exactly 45 files; the working tree additionally holds 3 MB of run output under `results/` and two `__pycache__` directories, all of which are ignored in the source and would be noise here. Using `git archive` or an explicit file list also preserves file modes, which a hand-assembled copy loses silently.
- KTD2. Relocate without editing any script. Every shell entry point derives its own root with `cd "$(dirname "${BASH_SOURCE[0]}")/.."` and sources `./lib.sh`, which sets `PT_ROOT` from `BASH_SOURCE`; every Python entry point uses `Path(__file__).parent` or `os.path.dirname(__file__)`. No file under the source harness contains a `../..` traversal, an absolute path, or a reference to `go.mod`, a `Makefile` target, or `hack/`. The directory is already self-locating, so moving it is sufficient and any script edit would be unnecessary risk against R3.
- KTD3. Start fresh history with a single import commit rather than grafting the source's commits. The source commits are interleaved with unrelated operator work on a fork branch, so a graft would import that noise, and the port needs an adaptation commit on top regardless. Record the source commit in the import commit message instead. Chosen over `git subtree` and `git filter-repo`.
- KTD4. Build the root `.gitignore` from what actually bore on these files, not by copying the operator's. Exactly three operator-root rules currently reach the harness: `*.txt` and `*.md`, which exist for the operator's local-notes policy and have no purpose in a docs-first repo, and `__pycache__/`, which is the only one carrying real protection. Copying the operator file wholesale would import two rules that then need negations to undo; omitting `__pycache__/` would let a fresh `git add .` commit the two `.pyc` files sitting in the source tree today.
- KTD5. Declare PyYAML in a `requirements.txt` rather than guarding the import. `generate-report.py` imports `yaml` unguarded at line 13 and uses it at lines 85-86 to read rule counts out of the ruleset manifests; PyYAML was supplied by the operator's `hack/requirements.txt`, which stays behind. Guarding the import would silently degrade the rule counts the matrix report is built on, which is worse than failing on a missing dependency. Note that `scripts/report.py` already guards its own `yaml` import and keeps working either way.
- KTD6. `CLAUDE.md` owns the agent-facing contract and `README.md` stays the owner of the methodology. The README is 859 lines and already states the methodology, the validity criteria, and the confounders well. `CLAUDE.md` states the rules an agent must not violate, routes to the entry points, and links to the README for the reasoning. The ported agent skill states the same guardrail numbers a third time, so it cites the README as well, and `CLAUDE.md` is authoritative when the two agent-facing files disagree. Three uncited copies of the methodology would drift against each other.
- KTD7. Both report generators ship. `scripts/report.py` computes the delta against the WAF-off baseline across repeats and is the one to report from; `generate-report.py` renders the full matrix. The source README already documents the division, so shipping both costs nothing and dropping either loses a capability.
- KTD8. Sample run output ships as a labeled fixture under `testdata/`, outside `results/`. Without it, roughly a third of the harness by volume, the two report generators, cannot be executed at all until someone books a cluster for the better part of an hour. The fixture is about 80 KB drawn from the source's existing output and is named so it can never be mistaken for a measurement of this repo. This is a deliberate narrow exception to leaving the source's run output behind.

### Assumptions

- The import targets the `main` branch of this repo, which currently has no commits.
- The operator project publishes `kubectl-coraza` as a release artifact, which the CRS regeneration instructions can point at. If it does not, that section states the plugin must be built from the operator repo and names it.

### Implementation Constraints

- Do not run the harness against a cluster as part of this work. Verification here is static plus the no-cluster report path.
- Preserve the source's own comments verbatim, including the ones explaining past bug fixes. They are the record of why the code is shaped the way it is.

---

## Output Structure

```
waf-perf-test/
├── CLAUDE.md                     # agent contract: guardrails + routing (new)
├── LICENSE                       # Apache-2.0 (new)
├── NOTICE                        # vendored CoreRuleSet attribution (new)
├── README.md                     # methodology, architecture, troubleshooting (ported, links rewritten)
├── requirements.txt              # PyYAML (new)
├── .gitignore                    # rebuilt for this repo (new)
├── lib.sh                        # shared config + helpers
├── run-comprehensive-tests.sh    # the 12-cell matrix + report
├── generate-report.py            # matrix report generator
├── analyze-results.py            # data analysis helper
├── .claude/
│   └── skills/perf-test/SKILL.md # ported agent skill
├── scripts/                      # setup, waf, run, suite, collect, report, teardown
├── scenarios/                    # QPS / duration / connections
├── manifests/
│   ├── backend.yaml, loadgen.yaml, gateway.yaml, engine.yaml
│   ├── rulesets/                 # minimal, medium, crs
│   └── load-profiles/            # request shapes, payloads, gen-payloads.sh
├── templates/
│   └── report-template.html
├── testdata/
│   └── sample-results/           # report-generator fixture (new)
└── docs/plans/                   # this plan
```

---

## Implementation Units

### U1. Land the tracked harness at the repo root

- **Goal:** Every git-tracked file from the source harness exists at this repo's root with its original content and mode.
- **Requirements:** R1, R2, R3
- **Dependencies:** none
- **Files:** the 45 paths listed by `git ls-files` under the source harness, re-rooted. Notably `lib.sh`, `run-comprehensive-tests.sh`, `generate-report.py`, `analyze-results.py`, `scripts/` (8 files), `scenarios/` (5 files), `manifests/` (4 YAML plus `rulesets/` and `load-profiles/`), `templates/report-template.html`, and the two per-directory `.gitignore` files.
- **Approach:**
  1. Export from the source index rather than the working tree, so `results/` and `__pycache__/` cannot come along.
  2. Re-root every path by stripping the `test/performance/` prefix.
  3. Carry the source harness's own `.gitignore` for now; U2 decides what the root file finally holds.
  4. Correct the one mode anomaly the source carries: `analyze-results.py` has a `python3` shebang but is not executable. Everything else keeps its source mode, including `lib.sh`, whose executable bit is odd for a file that is only ever sourced but is not worth deviating from the faithful port to change.
- **Patterns to follow:** The source's directory shape is the pattern. Do not reorganize it.
- **Execution note:** This unit is a faithful materialization. Any content difference from the source other than that one mode correction is a defect in this unit, not an improvement.
- **Test scenarios:**
  - The set of tracked files in this repo, with the prefix stripped, equals the set the source index lists; neither side has an extra entry.
  - Content of every ported file is byte-identical to the source index version.
  - Exactly eleven files are staged as mode `100755`, and `analyze-results.py` is the twelfth after its correction.
  - No `results/` directory and no `__pycache__` directory is staged.
- **Verification:** A file-by-file comparison against the source index reports differences in no file. The mode count matches.

### U2. Root ignore rules and the Python dependency manifest

- **Goal:** A clean clone can be built on and committed to without staging generated artifacts, and its Python entry points run after a declared install.
- **Requirements:** R5, R6
- **Dependencies:** U1
- **Files:** `.gitignore`, `requirements.txt`, `manifests/load-profiles/payloads/.gitignore`
- **Approach:**
  1. Write a root `.gitignore` covering run output (`results/`), the generated dashboard (`dashboard.html`), Python caches (`__pycache__/`, `.mypy_cache/`), and ordinary editor and OS noise. Do not carry the operator's `*.txt` and `*.md` rules.
  2. Because `*.txt` is not carried, remove the `!*.txt` negation from the payloads `.gitignore` and the three-line comment above it that explains a blanket rule which no longer exists. Keep its `multipart.bin` and `json-100kb.json` entries, which exist for CRLF fragility and blob size respectively.
  3. Add `requirements.txt` pinning PyYAML, per KTD5.
  4. Fold the harness `.gitignore`'s two entries into the root file and delete the now-redundant per-directory file, or leave it; either is correct as long as the entries survive.
- **Approach note on the coupling:** the `!*.txt` negation and the root `*.txt` rule are a pair. Removing one without the other drops `payloads/form-urlencoded.txt` from the repo and breaks the `form-urlencoded` load profile on a fresh clone, with no error until a run sends an empty body.
- **Test scenarios:**
  - After `git add -A` on a tree containing a `__pycache__` directory and a generated `payloads/json-100kb.json`, neither is staged.
  - `payloads/form-urlencoded.txt` is tracked and is not ignored.
  - `pip install -r requirements.txt` followed by `python3 -c 'import yaml'` succeeds in a clean virtual environment.
  - On a machine without PyYAML, `python3 generate-report.py` fails at its top-level `yaml` import; after installing from the dependency manifest it gets past the import and reaches its results lookup. The script parses no arguments, so the import is the only thing this check isolates.
- **Verification:** `git check-ignore -v` on each payload file and on a scratch `__pycache__` path returns the expected rule or no match.

### U3. Rewrite the operator-tree references in the harness docs

- **Goal:** No instruction in the ported documentation points at a file, script, or command that does not exist in or next to this repo.
- **Requirements:** R4, R10
- **Dependencies:** U1
- **Files:** `README.md`, `manifests/load-profiles/COMMANDS.md`, `manifests/load-profiles/README.md`, `manifests/rulesets/crs.yaml` (header comment only)
- **Approach:**
  1. Rewrite the path strings: the file-structure tree's `test/performance/` root, the CRS output path in the regeneration snippet, and the `test/performance/scenarios/` reference in the load-profiles README.
  2. Replace the `hack/install-istio.sh` instruction, which is operator tooling that cannot be copied, with the upstream Istio and Sail Operator install references the source README already names in prose.
  3. Fix the CRS regeneration section, which is the one block that is genuinely unrunnable here. It calls `kubectl coraza generate coreruleset`, a plugin built only from the operator repo. State where to obtain the plugin, drop "from the repo root", and correct the redirect path. Apply the same correction to the duplicate command in the `crs.yaml` header comment.
  4. Rewrite the Related docs table. Seven of its nine rows point into the operator's `docs/` tree and `DEVELOPMENT.md`; convert those to upstream URLs. The load-profiles row and the agent-skill row resolve inside this repo once U1 and U4 land, so they stay relative.
  5. Correct the Dependencies section, which claims only "Python 3.7+" and must now name the PyYAML requirement U2 adds.
  6. Leave the Known limitations section's existing entries intact and add the deferred defects this plan records, so R10 is served where a reader already looks.
- **Patterns to follow:** The README's existing voice and table shapes. This is an edit, not a rewrite.
- **Test scenarios:**
  - A search of the repo for `test/performance`, excluding `docs/`, returns no matches. Exactly three ported files carry the string today: the harness README, the load-profiles README, and the commands reference.
  - Every relative link in `README.md` resolves to a file in this repo; every link that does not is an absolute URL.
  - The Known limitations section names the hardcoded cluster facts in the report generators.
- **Verification:** A link check over the ported markdown reports no unresolvable relative target.

### U4. Port the agent skill

- **Goal:** The bundled `perf-test` skill drives this repo correctly and routes to everything the repo can do.
- **Requirements:** R9, R4
- **Dependencies:** U1, U3
- **Files:** `.claude/skills/perf-test/SKILL.md`
- **Approach:**
  1. Copy the source skill. It lives at `.claude/skills/perf-test/SKILL.md` in the operator repo root rather than inside the harness directory, so the U1 export does not carry it and it must be fetched separately. Rewrite its twenty-eight `test/performance/` path strings. The sentence stating that the scripts `cd` to their own directory and can be invoked from anywhere stays true and needs only the directory name changed.
  2. Apply the same CRS-regeneration correction as U3, since the skill repeats that block.
  3. Give the prerequisite line that says the operator must already be installed a pointer to where the operator comes from, since there is no longer an adjacent `config/` or Helm chart. Do the same for the ServiceMonitor and PodMonitor the metrics mode depends on.
  4. Correct the configuration table's `FAILURE_POLICY` row, which documents `fail`/`pass`. `scripts/waf.sh` accepts only `fail` or `allow` and exits with an error otherwise, and `manifests/engine.yaml` agrees. This is a pre-existing error, corrected here because this unit authors the file and shipping a knowingly wrong flag value is not a faithful port.
  5. Add the three entry points the skill omits: `run-comprehensive-tests.sh`, `generate-report.py`, and `analyze-results.py`. In this repo the skill is the only thing routing an agent to them. Mark the matrix runner and its report generator as indicative-only where they appear, because a single repeat per cell and the hardcoded cluster facts make their output unreportable. An agent that loads the skill without reading `CLAUDE.md` must still get that caveat with the routing.
- **Patterns to follow:** The skill's existing mode table and its stance that the scripts are the source of truth and the skill adds ordering and guardrails.
- **Test scenarios:**
  - Every command in the mode table names a path that exists in this repo.
  - The documented value set for every environment knob matches what the corresponding script validates, checked against `waf.sh`, `run.sh`, `suite.sh`, and `lib.sh`.
  - The skill's frontmatter description no longer names a directory that does not exist.
- **Verification:** Each table command resolves to a real file, and each documented flag value appears in the accepting script's validation.

### U5. Write CLAUDE.md

- **Goal:** An agent that reads only this file can run the harness correctly and knows when to throw a result away.
- **Requirements:** R8, R10
- **Dependencies:** U3, U4
- **Files:** `CLAUDE.md`
- **Approach:**
  1. Open with what the repo is and what it measures: the WASM module inside the Gateway pod's Envoy, driven by fortio from inside the cluster, reported as a delta against a WAF-off baseline and never as an absolute.
  2. State the guardrails as rules rather than prose, drawn from the README's methodology and validity criteria: capture the baseline in the same session, change one axis per run, wait out the settle window after toggling the WAF, discard the warm-up, repeat at least three times and report the median with its spread, and confirm the filter actually ran.
  3. State what invalidates a run: a non-zero error rate outside the attack profiles, an actual rate that misses the requested rate by more than about five percent, a shape probe that returned the wrong status, or a plugin reload inside the window.
  4. Route to the entry points and to the skill, and name the prerequisites the harness does not install.
  5. Name the known defects that would otherwise mislead an agent reading a report, especially the hardcoded cluster facts and the single-repeat matrix.
  6. Link to `README.md` for the reasoning behind each rule rather than restating it, per KTD6.
- **Patterns to follow:** The source operator repo's own `CLAUDE.md` for register and density. It leads with what the project is, then commands, then architecture, and states constraints flatly.
- **Execution note:** Write this through `ce-noslop`. It is the file an agent reads first and padding in it costs every future run.
- **Test scenarios:**
  - Every command and path the file names exists in this repo.
  - Every numeric guardrail it states matches its source: the warm-up and settle defaults against `run.sh` and `suite.sh`, the validity thresholds against the README's validity criteria.
  - No methodology rule is stated in full in more than one of `CLAUDE.md`, `README.md`, and the ported agent skill without the duplicate citing the README, and every guardrail number is identical across all three.
- **Verification:** An agent given only this file and the repo can name the baseline requirement, the settle requirement, and two conditions that invalidate a run.

### U6. License and attribution

- **Goal:** The repo is legally usable and the content it redistributes is attributed.
- **Requirements:** R7
- **Dependencies:** U1
- **Files:** `LICENSE`, `NOTICE`, `README.md`
- **Approach:**
  1. Add the Apache-2.0 license the operator project uses, so the extracted harness keeps the license it was written under.
  2. Add a `NOTICE` attributing the OWASP CoreRuleSet content vendored into `manifests/rulesets/crs.yaml`, which is a generated 20,496-line file carrying its own in-file CRS notices and is redistributed here.
  3. Reference both from the README.
- **Test scenarios:** `Test expectation: none -- licensing files carry no behavior.`
- **Verification:** `LICENSE` and `NOTICE` exist at the root, the `NOTICE` names the CoreRuleSet and its license, and the README references both.

### U7. Clean-clone verification and the report fixture

- **Goal:** Someone can confirm the port worked without a cluster.
- **Requirements:** R11, R1, R6
- **Dependencies:** U1, U2
- **Files:** `testdata/sample-results/` (twelve fortio JSON files and their summary siblings, about 80 KB), `testdata/sample-results/README.md`
- **Approach:**
  1. Copy the source's twelve `fixed-500qps+*__waf-*__*.json` files and their `.summary.txt` siblings into `testdata/sample-results/`. They are about 6.4 KB each. Placing them outside `results/` keeps them out of the ignore rule and out of the generators' default search path.
  2. Write a short README beside them stating plainly that they are a fixture for exercising the report code, that they were measured on another cluster, and that no number in them is reportable here. This is the whole reason they can ship without recreating the misattribution problem.
  3. Confirm `scripts/report.py` renders from the fixture, running it once per fixture profile with both `--results` pointed at the fixture directory and `--scenario` naming that profile. The flag is required, not optional: the fixture spans three request shapes and the script refuses to run when it finds more than one and no scenario is named.
  4. Confirm `generate-report.py` renders by copying the fixture into `results/` first, since it resolves its input directory from its own location with no flag to override.
  5. Delete the staged copy and the report it produced once the gate passes. The generated file claims twelve completed tests on the author's cluster, carries nothing identifying it as fixture output, and sits in an ignored directory where git would never surface it.
- **Execution note:** This is smoke proof of the relocation, not a test of report correctness. The generators' arithmetic is unchanged by this work and is not under test here.
- **Test scenarios:**
  - `scripts/report.py` writes an HTML file and exits zero for each of the three fixture profiles, given `--results` and the matching `--scenario`.
  - `generate-report.py` with the fixture staged into `results/` writes `results/performance-report.html` and exits zero.
  - Both outputs open in a browser with chart data present rather than empty placeholders.
  - The fixture directory is tracked by git and is not matched by any ignore rule.
  - After the gate, nothing generated from the fixture remains under `results/`.
  - `manifests/load-profiles/gen-payloads.sh` run twice from a clean tree produces byte-identical output both times.
- **Verification:** Both generators produce a non-empty HTML file from the fixture on a machine with no cluster access.

---

## Verification Contract

| Gate | What it proves | Applies to |
|---|---|---|
| File-by-file comparison against the source index | The port changed nothing it should not have | U1 |
| `git ls-files --stage` mode census | Executable bits survived; expect eleven `100755` plus the corrected `analyze-results.py` | U1 |
| `bash -n` on all nine shell files | No syntax damage in transit | U1 |
| `shellcheck` on all nine shell files | Matches the source's own baseline, which the files' inline directives show was maintained | U1 |
| `python3 -m py_compile` on the three Python files | No syntax damage in transit | U1 |
| `git check-ignore -v` on payload, cache, and result paths | Ignore rules behave as U2 intends | U2 |
| `pip install -r requirements.txt` in a clean virtual environment, then import `yaml` | R6 holds off this machine | U2 |
| Repo-wide search for `test/performance`, excluding `docs/` | No occurrence survived the rewrite | U3, U4 |
| Both report generators run against the fixture, then their output is removed | The relocated report path works with no cluster, and no fixture-derived report is left behind | U7 |
| `gen-payloads.sh` run twice, outputs compared | Payload generation is still deterministic | U7 |

No cluster run is required to call this work done. A first real run against a cluster is the natural next step and belongs to whoever has one.

---

## Definition of Done

- All eleven requirements are met, and each is traceable to a unit that delivered it.
- Every gate in the Verification Contract has been run and passed, with failures reported rather than worked around.
- The source harness directory and this repo's root differ only in documentation, ignore rules, and the files this plan adds.
- No file in this repo instructs a reader or an agent to run something that does not exist.
- Nothing from an abandoned approach remains in the tree: no leftover copies of the source directory, no scratch scripts, no partially rewritten documents.
- The import commit records the source repository, branch, and commit it was taken from.

---

## Risks & Dependencies

- **Prerequisite, must be handled before the first commit.** The parent directory of this repo on the implementer's machine is itself a git clone of this same remote, also with no commits. A commit made from the parent directory would land in the wrong working tree and look as though it succeeded. Confirm the working tree before staging anything, and raise the duplicate clone rather than deleting it.
- **Mode loss is silent.** A copy through a filesystem that drops permission bits, or a repository with `core.fileMode` disabled, stages every script as non-executable with no error. The mode census in the Verification Contract is the only thing that catches it.
- **The payload ignore pair.** Described in U2. Getting it half right removes a tracked payload and breaks one load profile at runtime rather than at commit time.
- **The fixture could be mistaken for a measurement.** Mitigated by its directory name, its README, the deletion of anything generated from it, and the harness README's existing instruction never to quote figures from a previous run. The exposure that survives is a report someone generates from the fixture and shares before deleting it; such a report asserts the author's cluster as fact with no route back to the caveat. If that is judged too much, drop U7's fixture and accept that the report path cannot be verified without a cluster.
- **Upstream operator dependency.** The harness needs the operator's CRDs in the cluster and, for CRS regeneration, its `kubectl-coraza` plugin. That coupling is inherent and is documented, not removed.

---

## Sources & Research

- Source harness: `test/performance/` on the `performance-testing` branch of the operator fork, head `8ba846c`, 45 tracked files.
- `source: README.md` lines 410-462 (methodology and validity criteria) and 577-610 (KPIs and confounders) are the basis for the guardrails `CLAUDE.md` must carry in U5.
- `source: README.md` lines 499-526 document the division between the two report generators that KTD7 preserves.
- `source: lib.sh` line 9 sets `PT_ROOT` from `BASH_SOURCE`, which is the evidence for KTD2.
- `source: generate-report.py` line 13 and lines 85-86 are the unguarded PyYAML dependency behind KTD5; `source: scripts/report.py` lines 18-21 show the guarded alternative.
- `source: generate-report.py` lines 1226-1230 and `source: templates/report-template.html` lines 884, 908, and 924 are the hardcoded cluster facts deferred above.
- `source: manifests/load-profiles/payloads/.gitignore` lines 1-4 document the `*.txt` coupling U2 must resolve.
- The agent skill U4 ports is `.claude/skills/perf-test/SKILL.md` at the operator repo root, outside the harness directory and therefore outside the U1 export.
- The operator's own `CLAUDE.md` is the register and density model for U5.
