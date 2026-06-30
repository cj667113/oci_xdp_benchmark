#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

RUN_ID="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"
RULE_COUNT="${RULE_COUNT:-128}"
DURATION="${DURATION:-30}"
PARALLEL="${PARALLEL:-8}"
UDP_RATE="${UDP_RATE:-10G}"
XDP_MODE="${XDP_MODE:-xdpgeneric}"
LIMIT="${LIMIT:-}"
MODES="${MODES:-iptables nftables xdp}"

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
    -e firewall_rule_count="${RULE_COUNT}" \
    -e xdp_mode="${XDP_MODE}"

  echo "=== running ${mode} benchmark; run_id=${RUN_ID}; limit=${limit_pattern} ==="
  ansible-playbook -i ../inventory.ini run_tests.yml \
    --limit "${limit_pattern}" \
    -e test_label="${mode}" \
    -e run_id="${RUN_ID}" \
    -e duration="${DURATION}" \
    -e parallel_streams="${PARALLEL}" \
    -e udp_rate="${UDP_RATE}"
}

run_xdp_mode() {
  local limit_pattern
  limit_pattern="$(limit_for_env xdp)"

  echo "=== configuring xdp; rule_count=${RULE_COUNT}; xdp_mode=${XDP_MODE}; limit=${limit_pattern} ==="
  ansible-playbook -i ../inventory.ini site.yml \
    --limit "${limit_pattern}" \
    -e firewall_rule_count="${RULE_COUNT}" \
    -e xdp_mode="${XDP_MODE}"

  echo "=== running xdp benchmark; run_id=${RUN_ID}; limit=${limit_pattern} ==="
  ansible-playbook -i ../inventory.ini run_tests.yml \
    --limit "${limit_pattern}" \
    -e test_label="xdp" \
    -e run_id="${RUN_ID}" \
    -e duration="${DURATION}" \
    -e parallel_streams="${PARALLEL}" \
    -e udp_rate="${UDP_RATE}"
}

for mode in ${MODES}; do
  case "${mode}" in
    iptables|nftables)
      run_firewall_mode "${mode}"
      ;;
    xdp)
      run_xdp_mode
      ;;
    *)
      echo "Unsupported mode '${mode}'. Valid MODES entries: iptables nftables xdp" >&2
      exit 2
      ;;
  esac
done

python3 ../tools/summarize_results.py "../results/${RUN_ID}"
