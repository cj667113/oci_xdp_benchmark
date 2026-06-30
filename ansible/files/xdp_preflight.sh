#!/usr/bin/env bash
set -u

usage() {
  cat >&2 <<'EOF'
Usage: xdp_preflight.sh IFACE MODE PLAIN_OBJECT FRAGS_OBJECT RESULT_FILE

MODE is one of:
  xdpgeneric  Require generic/SKB-mode XDP.
  xdpdrv      Require native driver-mode XDP (plain or xdp.frags).
  auto        Prefer native XDP and fall back to generic XDP.
EOF
  exit 2
}

if [ "$#" -ne 5 ]; then
  usage
fi

IFACE="$1"
REQUESTED_MODE="$2"
PLAIN_OBJECT="$3"
FRAGS_OBJECT="$4"
RESULT_FILE="$5"
REPORT_FILE="${RESULT_FILE%.env}.txt"

case "$REQUESTED_MODE" in
  xdpgeneric|xdpdrv|auto) ;;
  *)
    printf "Unsupported XDP mode: %s\n" "$REQUESTED_MODE" >&2
    usage
    ;;
esac

if [ "$(id -u)" -ne 0 ]; then
  echo "xdp_preflight.sh must run as root" >&2
  exit 1
fi

for object in "$PLAIN_OBJECT" "$FRAGS_OBJECT"; do
  if [ ! -r "$object" ]; then
    printf "XDP object is not readable: %s\n" "$object" >&2
    exit 1
  fi
done

if ! ip link show dev "$IFACE" >/dev/null 2>&1; then
  printf "Network interface does not exist: %s\n" "$IFACE" >&2
  exit 1
fi

mkdir -p "$(dirname "$RESULT_FILE")"
: > "$REPORT_FILE"
WORKDIR=$(mktemp -d /tmp/oci-xdp-preflight.XXXXXX)

log() {
  printf "%s\n" "$*" | tee -a "$REPORT_FILE"
}

detach_xdp() {
  ip link set dev "$IFACE" xdp off >/dev/null 2>&1 || true
  ip link set dev "$IFACE" xdpdrv off >/dev/null 2>&1 || true
  ip link set dev "$IFACE" xdpgeneric off >/dev/null 2>&1 || true
  ip link set dev "$IFACE" xdpoffload off >/dev/null 2>&1 || true
}

cleanup() {
  detach_xdp
  rm -rf "$WORKDIR"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

DRIVER=$(ethtool -i "$IFACE" 2>/dev/null | awk -F': ' '/^driver:/ {print $2; exit}')
DRIVER_VERSION=$(ethtool -i "$IFACE" 2>/dev/null | awk -F': ' '/^version:/ {print $2; exit}')
FIRMWARE_VERSION=$(ethtool -i "$IFACE" 2>/dev/null | awk -F': ' '/^firmware-version:/ {print $2; exit}')
MTU=$(ip -o link show dev "$IFACE" | awk '{for (i=1; i<=NF; i++) if ($i == "mtu") {print $(i+1); exit}}')

log "OCI XDP compatibility preflight"
log "interface=${IFACE}"
log "requested_mode=${REQUESTED_MODE}"
log "kernel=$(uname -r)"
log "driver=${DRIVER:-unknown}"
log "driver_version=${DRIVER_VERSION:-unknown}"
log "firmware_version=${FIRMWARE_VERSION:-unknown}"
log "mtu=${MTU:-unknown}"

if command -v bpftool >/dev/null 2>&1; then
  log "bpftool=$(bpftool version 2>/dev/null | head -1 || true)"
else
  log "bpftool=unavailable (attach tests remain authoritative)"
fi

PROBE_RESULT="no"
probe_attach() {
  local label="$1"
  local mode="$2"
  local object="$3"
  local section="$4"
  local probe_log="${WORKDIR}/${label}.log"

  detach_xdp
  if ip link set dev "$IFACE" "$mode" obj "$object" sec "$section" >"$probe_log" 2>&1; then
    PROBE_RESULT="yes"
    log "${label}=PASS (mode=${mode}, section=${section})"
    ip -details link show dev "$IFACE" >> "$REPORT_FILE" 2>&1 || true
  else
    PROBE_RESULT="no"
    log "${label}=FAIL (mode=${mode}, section=${section})"
    sed 's/^/  /' "$probe_log" | tail -20 | tee -a "$REPORT_FILE"
  fi
  detach_xdp
}

# Test the actual benchmark program rather than a minimal XDP_PASS program. This
# proves both driver capability and verifier acceptance of the code we will run.
probe_attach "generic_plain" "xdpgeneric" "$PLAIN_OBJECT" "xdp"
GENERIC_SUPPORTED="$PROBE_RESULT"

probe_attach "native_plain" "xdpdrv" "$PLAIN_OBJECT" "xdp"
NATIVE_PLAIN_SUPPORTED="$PROBE_RESULT"

probe_attach "native_frags" "xdpdrv" "$FRAGS_OBJECT" "xdp.frags"
NATIVE_FRAGS_SUPPORTED="$PROBE_RESULT"

NATIVE_SUPPORTED="no"
if [ "$NATIVE_PLAIN_SUPPORTED" = "yes" ] || [ "$NATIVE_FRAGS_SUPPORTED" = "yes" ]; then
  NATIVE_SUPPORTED="yes"
fi

SELECTED_MODE=""
SELECTED_OBJECT=""
SELECTED_SECTION=""
SELECTION_ERROR=""

select_native() {
  if [ "$NATIVE_PLAIN_SUPPORTED" = "yes" ]; then
    SELECTED_MODE="xdpdrv"
    SELECTED_OBJECT="$PLAIN_OBJECT"
    SELECTED_SECTION="xdp"
  elif [ "$NATIVE_FRAGS_SUPPORTED" = "yes" ]; then
    SELECTED_MODE="xdpdrv"
    SELECTED_OBJECT="$FRAGS_OBJECT"
    SELECTED_SECTION="xdp.frags"
  else
    return 1
  fi
}

case "$REQUESTED_MODE" in
  xdpgeneric)
    if [ "$GENERIC_SUPPORTED" = "yes" ]; then
      SELECTED_MODE="xdpgeneric"
      SELECTED_OBJECT="$PLAIN_OBJECT"
      SELECTED_SECTION="xdp"
    else
      SELECTION_ERROR="generic XDP rejected the benchmark program"
    fi
    ;;
  xdpdrv)
    if ! select_native; then
      SELECTION_ERROR="native driver-mode XDP rejected both plain and xdp.frags variants"
    fi
    ;;
  auto)
    if ! select_native; then
      if [ "$GENERIC_SUPPORTED" = "yes" ]; then
        SELECTED_MODE="xdpgeneric"
        SELECTED_OBJECT="$PLAIN_OBJECT"
        SELECTED_SECTION="xdp"
      else
        SELECTION_ERROR="neither native nor generic XDP accepted the benchmark program"
      fi
    fi
    ;;
esac

write_env() {
  {
    printf 'XDP_IFACE=%q\n' "$IFACE"
    printf 'XDP_DRIVER=%q\n' "${DRIVER:-unknown}"
    printf 'XDP_MTU=%q\n' "${MTU:-unknown}"
    printf 'XDP_REQUESTED_MODE=%q\n' "$REQUESTED_MODE"
    printf 'XDP_GENERIC_SUPPORTED=%q\n' "$GENERIC_SUPPORTED"
    printf 'XDP_NATIVE_SUPPORTED=%q\n' "$NATIVE_SUPPORTED"
    printf 'XDP_NATIVE_PLAIN_SUPPORTED=%q\n' "$NATIVE_PLAIN_SUPPORTED"
    printf 'XDP_NATIVE_FRAGS_SUPPORTED=%q\n' "$NATIVE_FRAGS_SUPPORTED"
    printf 'XDP_SELECTED_MODE=%q\n' "$SELECTED_MODE"
    printf 'XDP_SELECTED_OBJECT=%q\n' "$SELECTED_OBJECT"
    printf 'XDP_SELECTED_SECTION=%q\n' "$SELECTED_SECTION"
  } > "$RESULT_FILE"
}

write_env

log "generic_supported=${GENERIC_SUPPORTED}"
log "native_supported=${NATIVE_SUPPORTED}"
log "native_plain_supported=${NATIVE_PLAIN_SUPPORTED}"
log "native_frags_supported=${NATIVE_FRAGS_SUPPORTED}"

if [ -n "$SELECTION_ERROR" ]; then
  log "verdict=FAIL: ${SELECTION_ERROR}"
  log "result_file=${RESULT_FILE}"
  log "report_file=${REPORT_FILE}"
  exit 1
fi

log "selected_mode=${SELECTED_MODE}"
log "selected_object=${SELECTED_OBJECT}"
log "selected_section=${SELECTED_SECTION}"
log "verdict=PASS"
log "result_file=${RESULT_FILE}"
log "report_file=${REPORT_FILE}"
