#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

RUN_ID="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"
RULE_COUNT="${RULE_COUNT:-128}"
DURATION="${DURATION:-30}"
PARALLEL="${PARALLEL:-8}"
UDP_RATE="${UDP_RATE:-10G}"
REPETITIONS="${REPETITIONS:-10}"
# Retained for the legacy MODES="xdp" alias. The explicit xdp-generic and
# xdp-native modes below do not use this override.
XDP_MODE="${XDP_MODE:-xdpgeneric}"
LIMIT="${LIMIT:-}"
MODES="${MODES:-iptables nftables xdp-generic xdp-native}"

if ! [[ "${REPETITIONS}" =~ ^[1-9][0-9]*$ ]]; then
  echo "REPETITIONS must be a positive integer; got '${REPETITIONS}'" >&2
  exit 2
fi

limit_for_env() {
  local env_group="$1"
  if [[ -n "${LIMIT}" ]]; then
    # Intersect the user-provided shape/pattern limit with the benchmark environment.
    # Examples: LIMIT=e6 -> e6:&fw or e6:&xdp
    printf '%s:&%s' "${LIMIT}" "${env_group}"
  else
    printf '%s' "${env_group}"
  fi
}

run_firewall_mode() {
  local mode="$1"
  local limit_pattern
  limit_pattern="$(limit_for_env fw)"

  echo "=== configuring ${mode}; rule_count=${RULE_COUNT}; limit=${limit_pattern} ==="
  ansible-playbook -i ../inventory.ini site.yml \
    --limit "${limit_pattern}" \
    -e firewall_mode="${mode}" \
    -e firewall_rule_count="${RULE_COUNT}"

  echo "=== running ${mode} benchmark; run_id=${RUN_ID}; limit=${limit_pattern} ==="
  ansible-playbook -i ../inventory.ini run_tests.yml \
    --limit "${limit_pattern}" \
    -e test_label="${mode}" \
    -e run_id="${RUN_ID}" \
    -e duration="${DURATION}" \
    -e parallel_streams="${PARALLEL}" \
    -e udp_rate="${UDP_RATE}" \
    -e benchmark_repetitions="${REPETITIONS}"
}

run_xdp_mode() {
  local test_mode="$1"
  local attach_mode="$2"
  local limit_pattern
  limit_pattern="$(limit_for_env xdp)"

  echo "=== configuring ${test_mode}; rule_count=${RULE_COUNT}; xdp_mode=${attach_mode}; limit=${limit_pattern} ==="
  ansible-playbook -i ../inventory.ini site.yml \
    --limit "${limit_pattern}" \
    -e firewall_rule_count="${RULE_COUNT}" \
    -e xdp_mode="${attach_mode}"

  echo "=== running ${test_mode} benchmark; run_id=${RUN_ID}; limit=${limit_pattern} ==="
  ansible-playbook -i ../inventory.ini run_tests.yml \
    --limit "${limit_pattern}" \
    -e test_label="${test_mode}" \
    -e run_id="${RUN_ID}" \
    -e duration="${DURATION}" \
    -e parallel_streams="${PARALLEL}" \
    -e udp_rate="${UDP_RATE}" \
    -e benchmark_repetitions="${REPETITIONS}"
}

for mode in ${MODES}; do
  case "${mode}" in
    iptables|nftables)
      run_firewall_mode "${mode}"
      ;;
    xdp-generic)
      run_xdp_mode "xdp-generic" "xdpgeneric"
      ;;
    xdp-native)
      run_xdp_mode "xdp-native" "xdpdrv"
      ;;
    xdp)
      # Backward-compatible alias for existing automation. New runs should use
      # xdp-generic and xdp-native so result labels are unambiguous.
      run_xdp_mode "xdp" "${XDP_MODE}"
      ;;
    *)
      echo "Unsupported mode '${mode}'. Valid MODES entries: iptables nftables xdp-generic xdp-native xdp" >&2
      exit 2
      ;;
  esac
done

python3 ../tools/summarize_results.py "../results/${RUN_ID}"
