# shellcheck shell=bash
# Limits for tests/bench-scan.sh in .github/workflows/bench.yml (a GitHub ubuntu-24.04 runner),
# in seconds: the median of 5 rounds. Lower them as scans get faster; raise them only with a reason.
# shellcheck disable=SC2034 # read by tests/bench-scan.sh
SCAN_FIRST_MAX=20
SCAN_AGAIN_MAX=10
