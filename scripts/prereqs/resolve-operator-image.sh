#!/usr/bin/env bash
#
# resolve-operator-image.sh - Find a Coraza operator image that runs on this
# cluster's architecture, from the downstream Konflux build registry.
#
#   eval "$(scripts/prereqs/resolve-operator-image.sh)"
#   scripts/prereqs/install-operator.sh
#
# Env: CORAZA_QUAY_REPO (default in lib.sh), ARCH to skip asking the cluster
#
# The chart's default image is published for linux/amd64 only, so on arm64
# install-operator.sh stops before installing anything. The downstream builds
# are multi-arch. This finds the newest one that actually carries the
# architecture you need and prints the two variables install-operator.sh reads.
#
# Everything human-readable goes to stderr, so stdout is exactly the export
# lines and the eval above is safe.
#
# This is a staging registry, not a release channel. See the note on
# CORAZA_QUAY_REPO in lib.sh before using the result for anything reportable.
#
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
# shellcheck source=../../lib.sh
source ./lib.sh
require_cmd python3

# Unlike the other prereq scripts this one is useful without a cluster — you
# may be resolving an image to pin before you have one — so the cluster is
# only consulted when ARCH was not given.
if [[ -z "${ARCH:-}" ]]; then
  preflight
  # Every node, not just the first. A mixed-architecture cluster can schedule
  # the operator on an amd64 node, and amd64 is the one arch every build
  # publishes, so prefer it whenever it is available. Listing nodes is also a
  # cluster-scoped read that plenty of namespace-scoped credentials lack: an
  # empty answer means "could not look", not "no nodes", so assume amd64
  # rather than refuse.
  node_arches="$("${CLI}" get nodes \
    -o jsonpath='{range .items[*]}{.status.nodeInfo.architecture}{"\n"}{end}' \
    2>/dev/null | sort -u | tr '\n' ' ' || true)"
  if [[ -z "${node_arches// /}" ]]; then
    warn "cannot read node architectures; assuming amd64"
    ARCH=amd64
  elif [[ " ${node_arches} " == *" amd64 "* ]]; then
    ARCH=amd64
  else
    ARCH="${node_arches%% *}"
  fi
  log "Cluster architecture: ${node_arches:-unknown} — using ${ARCH}" >&2
fi

log "Searching ${CORAZA_QUAY_REPO} for ${ARCH}" >&2

# No f-string: an escaped quote inside an f-string expression is a syntax error
# before Python 3.12, and install-operator.sh already lost a version line to it.
resolved="$(python3 -c '
import json, re, sys, urllib.request

repo, want = sys.argv[1], sys.argv[2]

def get(url, headers=None):
    req = urllib.request.Request(url, headers=headers or {})
    with urllib.request.urlopen(req, timeout=30) as r:
        return r.read()

# Konflux tags every push build with the 40-char upstream commit SHA. That one
# pattern is the whole filter: it drops the on-pr-* builds (which expire), the
# -linux-<arch> children of each index, the pipeline-run names, and the .git /
# .prefetch / .att / .sig attachments. The repo holds ~500 tags; almost none of
# them are images you would install.
tags, page = [], 1
while page <= 20:
    d = json.loads(get(
        "https://quay.io/api/v1/repository/%s/tag/?onlyActiveTags=true&limit=100&page=%d"
        % (repo, page)))
    tags.extend(d.get("tags", []))
    if not d.get("has_additional"):
        break
    page += 1

is_sha = re.compile(r"^[0-9a-f]{40}$")
builds = [t for t in tags
          if is_sha.match(t.get("name", ""))
          and t.get("is_manifest_list")
          and "end_ts" not in t]
builds.sort(key=lambda t: t.get("start_ts", 0), reverse=True)
if not builds:
    sys.exit("no push-build tags in %s" % repo)

token = json.loads(get(
    "https://quay.io/v2/auth?service=quay.io&scope=repository:%s:pull" % repo))["token"]
accept = ("application/vnd.docker.distribution.manifest.list.v2+json, "
          "application/vnd.oci.image.index.v1+json")

# Multi-arch is recent; builds before late October 2026 are x86-64 only. Walk
# back from the newest rather than failing on it, so an older cluster arch
# still resolves to something installable.
for i, t in enumerate(builds[:10]):
    m = json.loads(get("https://quay.io/v2/%s/manifests/%s" % (repo, t["manifest_digest"]),
                       {"Authorization": "Bearer " + token, "Accept": accept}))
    arches = sorted(x["platform"]["architecture"] for x in m.get("manifests", []))
    if want in arches:
        print(json.dumps({"tag": t["name"], "digest": t["manifest_digest"],
                          "arches": arches, "skipped": i}))
        break
else:
    sys.exit("none of the %d newest builds publish %s" % (min(10, len(builds)), want))
' "${CORAZA_QUAY_REPO}" "${ARCH}")"

eval "$(python3 -c '
import json, sys
d = json.loads(sys.argv[1])
print("tag=%s" % d["tag"])
print("digest=%s" % d["digest"])
print("arches=\"%s\"" % ", ".join(d["arches"]))
print("skipped=%d" % d["skipped"])' "${resolved}")"

if (( skipped > 0 )); then
  warn "skipped ${skipped} newer build(s) that do not publish ${ARCH}"
fi

ok "${tag}" >&2
log "  digest:  ${digest}" >&2
log "  arches:  ${arches}" >&2
warn "Staging build: no version label, and the tag may be garbage-collected."
warn "It is also a different release line from chart ${CORAZA_CHART_VERSION:-(newest)}."
warn "A newer manager on older CRDs fails as status patches that cannot find"
warn "their object — see the CRD note in install-operator.sh."

echo "export CORAZA_IMAGE_REPO=quay.io/${CORAZA_QUAY_REPO}"
echo "export CORAZA_IMAGE_TAG=${tag}"
