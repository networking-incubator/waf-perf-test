#!/usr/bin/env bash
#
# install-all.sh - Install every prerequisite, in order, then verify.
#
#   scripts/prereqs/install-all.sh
#
# Safe to re-run: each step is a no-op when its piece is already present.
#
# This is a cluster change, not a measurement step. Run it before the session
# you intend to report, never between a baseline and a WAF-on run — installing
# or upgrading Istio restarts the gateway proxy and invalidates the comparison.
#
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
# shellcheck source=../../lib.sh
source ./lib.sh
preflight
require_platform_match

# OpenShift ships the Gateway API CRDs; install-gateway-api.sh refuses there.
if ! cluster_is_openshift; then
  ./scripts/prereqs/install-gateway-api.sh
fi
./scripts/prereqs/install-istio.sh
./scripts/prereqs/install-operator.sh

echo
./scripts/prereqs/check.sh
