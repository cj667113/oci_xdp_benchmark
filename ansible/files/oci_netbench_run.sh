#!/usr/bin/env bash
set -u

TARGET_IP="${1:?target ip required}"
LABEL="${2:?label required}"
PORT="${3:-5201}"
UDP_RATE="${4:-10G}"
DURATION="${5:-30}"
PARALLEL="${6:-8}"
PING_COUNT="${7:-100}"
UDP_LEN="${8:-64}"

BASE="/tmp/oci-netbench"
OUT="${BASE}/${LABEL}"
mkdir -p "${OUT}"

run_capture() {
  local name="$1"
  shift
  echo "+ $*" > "${OUT}/${name}.cmd"
  timeout "$((DURATION + 45))" "$@" > "${OUT}/${name}.out" 2> "${OUT}/${name}.err"
  echo "$?" > "${OUT}/${name}.exit"
}

{
  echo "{"
  echo "  \"label\": \"${LABEL}\","
  echo "  \"hostname\": \"$(hostname)\","
  echo "  \"target_ip\": \"${TARGET_IP}\","
  echo "  \"port\": ${PORT},"
  echo "  \"udp_rate\": \"${UDP_RATE}\","
  echo "  \"duration\": ${DURATION},"
  echo "  \"parallel\": ${PARALLEL},"
  echo "  \"udp_len\": ${UDP_LEN},"
  echo "  \"started_utc\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
  echo "  \"kernel\": \"$(uname -r)\""
  echo "}"
} > "${OUT}/metadata.json"

ip -s -j link show > "${OUT}/link_before.json" 2>/dev/null || true
tc -s qdisc show > "${OUT}/tc_before.txt" 2>/dev/null || true
nstat -az > "${OUT}/nstat_before.txt" 2>/dev/null || true

ping -c "${PING_COUNT}" -i 0.2 "${TARGET_IP}" > "${OUT}/ping.txt" 2> "${OUT}/ping.err"
echo "$?" > "${OUT}/ping.exit"

run_capture tcp_forward iperf3 --json --get-server-output -c "${TARGET_IP}" -p "${PORT}" -t "${DURATION}" -P "${PARALLEL}"
sleep 2
run_capture tcp_reverse iperf3 --json --get-server-output -R -c "${TARGET_IP}" -p "${PORT}" -t "${DURATION}" -P "${PARALLEL}"
sleep 2
run_capture udp_smallpps iperf3 --json --get-server-output -u -b "${UDP_RATE}" -l "${UDP_LEN}" -c "${TARGET_IP}" -p "${PORT}" -t "${DURATION}"
sleep 2
run_capture udp_throughput iperf3 --json --get-server-output -u -b "${UDP_RATE}" -l 1400 -c "${TARGET_IP}" -p "${PORT}" -t "${DURATION}"

ip -s -j link show > "${OUT}/link_after.json" 2>/dev/null || true
tc -s qdisc show > "${OUT}/tc_after.txt" 2>/dev/null || true
nstat -az > "${OUT}/nstat_after.txt" 2>/dev/null || true

TAR="/tmp/$(hostname)-${LABEL}.tar.gz"
tar -C "${BASE}" -czf "${TAR}" "${LABEL}"
echo "${TAR}"
