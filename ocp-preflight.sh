#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage:
  ocp-preflight.sh [config-file]
  ocp-preflight.sh -c <config-file>
  ocp-preflight.sh --config <config-file>
  ocp-preflight.sh --validate-config [config-file]
  ocp-preflight.sh -h | --help

Options:
  -c, --config <file>     Path to the configuration file
      --validate-config   Validate configuration and exit without running checks
  -h, --help              Show this help text
EOF
}

CONFIG_FILE="./ocp-preflight.conf"
VALIDATE_ONLY="no"

while (($# > 0)); do
  case "$1" in
    -c|--config)
      [[ $# -ge 2 ]] || { echo "ERROR: missing value for $1"; usage; exit 2; }
      CONFIG_FILE="$2"
      shift 2
      ;;
    --validate-config)
      VALIDATE_ONLY="yes"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      echo "ERROR: unknown option: $1"
      usage
      exit 2
      ;;
    *)
      if [[ "${CONFIG_FILE}" != "./ocp-preflight.conf" ]]; then
        echo "ERROR: multiple config files provided"
        usage
        exit 2
      fi
      CONFIG_FILE="$1"
      shift
      ;;
  esac
done

if (($# > 0)); then
  echo "ERROR: unexpected arguments: $*"
  usage
  exit 2
fi

if [[ ! -f "${CONFIG_FILE}" ]]; then
  echo "ERROR: config file not found: ${CONFIG_FILE}"
  exit 2
fi

if ! bash -n "${CONFIG_FILE}" >/dev/null 2>&1; then
  echo "ERROR: config file has invalid shell syntax: ${CONFIG_FILE}"
  exit 2
fi

# shellcheck disable=SC1090
source "${CONFIG_FILE}"

declare -p MASTER_NODES >/dev/null 2>&1 || MASTER_NODES=()
declare -p WORKER_NODES >/dev/null 2>&1 || WORKER_NODES=()
declare -p INGRESS_NODES >/dev/null 2>&1 || INGRESS_NODES=()
declare -p BOOT_ARTIFACTS >/dev/null 2>&1 || BOOT_ARTIFACTS=()

PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0

pass() { echo "[PASS] $*"; ((PASS_COUNT+=1)); }
fail() { echo "[FAIL] $*"; ((FAIL_COUNT+=1)); }
warn() { echo "[WARN] $*"; ((WARN_COUNT+=1)); }
info() { echo "[INFO] $*"; }

die() {
  echo "ERROR: $*"
  exit 2
}

need_cmd() {
  local cmd
  for cmd in "$@"; do
    command -v "${cmd}" >/dev/null 2>&1 || die "required command not found: ${cmd}"
  done
}

is_ipv4() {
  local ip="$1"
  local octet
  [[ "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS='.' read -r -a octets <<<"${ip}"
  for octet in "${octets[@]}"; do
    [[ "${octet}" =~ ^[0-9]+$ ]] || return 1
    ((octet >= 0 && octet <= 255)) || return 1
  done
}

is_yes_no() {
  [[ "$1" == "yes" || "$1" == "no" ]]
}

require_nonempty() {
  local name="$1"
  local value="${!name:-}"
  [[ -n "${value}" ]] || die "required config value is empty: ${name}"
}

tuple_name() { echo "${1%%:*}"; }
tuple_ip()   { echo "${1##*:}"; }

validate_tuple() {
  local tuple="$1"
  local label="$2"
  [[ "${tuple}" == *:* ]] || die "${label} must use shortname:ip format, got '${tuple}'"

  local short ip
  short="$(tuple_name "${tuple}")"
  ip="$(tuple_ip "${tuple}")"

  [[ -n "${short}" ]] || die "${label} has an empty node name"
  [[ "${short}" =~ ^[A-Za-z0-9._-]+$ ]] || die "${label} has an invalid node name: ${short}"
  is_ipv4 "${ip}" || die "${label} has an invalid IPv4 address: ${ip}"
}

validate_config() {
  require_nonempty PHASE
  require_nonempty DNS_SERVER
  require_nonempty CLUSTER_NAME
  require_nonempty BASE_DOMAIN
  require_nonempty API_VIP
  require_nonempty INGRESS_VIP
  require_nonempty BOOTSTRAP_NODE

  [[ "${PHASE}" == "pre-bootstrap" || "${PHASE}" == "post-bootstrap" ]] || \
    die "PHASE must be 'pre-bootstrap' or 'post-bootstrap', got '${PHASE}'"

  is_ipv4 "${DNS_SERVER}" || die "DNS_SERVER must be an IPv4 address, got '${DNS_SERVER}'"
  is_ipv4 "${API_VIP}" || die "API_VIP must be an IPv4 address, got '${API_VIP}'"
  is_ipv4 "${INGRESS_VIP}" || die "INGRESS_VIP must be an IPv4 address, got '${INGRESS_VIP}'"

  validate_tuple "${BOOTSTRAP_NODE}" "BOOTSTRAP_NODE"
  ((${#MASTER_NODES[@]} > 0)) || die "MASTER_NODES must contain at least one node"
  ((${#INGRESS_NODES[@]} > 0)) || die "INGRESS_NODES must contain at least one node"

  local tuple
  for tuple in "${MASTER_NODES[@]}"; do
    validate_tuple "${tuple}" "MASTER_NODES entry"
  done
  for tuple in "${WORKER_NODES[@]}"; do
    validate_tuple "${tuple}" "WORKER_NODES entry"
  done
  for tuple in "${INGRESS_NODES[@]}"; do
    validate_tuple "${tuple}" "INGRESS_NODES entry"
  done

  is_yes_no "${ENABLE_LB_SSH_CHECK:-no}" || die "ENABLE_LB_SSH_CHECK must be 'yes' or 'no'"
  is_yes_no "${ENABLE_BOOT_ARTIFACT_CHECK:-no}" || die "ENABLE_BOOT_ARTIFACT_CHECK must be 'yes' or 'no'"
  is_yes_no "${REQUIRE_PINNED_NIC:-no}" || die "REQUIRE_PINNED_NIC must be 'yes' or 'no'"

  if [[ "${ENABLE_LB_SSH_CHECK:-no}" == "yes" ]]; then
    require_nonempty LB_HOST
    require_nonempty LB_SSH_USER
    require_nonempty HAPROXY_CFG
  fi

  if [[ "${ENABLE_BOOT_ARTIFACT_CHECK:-no}" == "yes" ]]; then
    require_nonempty BOOT_METHOD
    [[ "${BOOT_METHOD}" == "ipxe" || "${BOOT_METHOD}" == "pxe" || "${BOOT_METHOD}" == "generic" ]] || \
      die "BOOT_METHOD must be one of: ipxe, pxe, generic"
    ((${#BOOT_ARTIFACTS[@]} > 0)) || die "BOOT_ARTIFACTS must contain at least one entry when boot artifact checks are enabled"
  fi

  if [[ "${REQUIRE_PINNED_NIC:-no}" == "yes" ]]; then
    require_nonempty EXPECT_BOOT_NIC
  fi
}

validate_config

if [[ "${VALIDATE_ONLY}" == "yes" ]]; then
  info "Configuration is valid: ${CONFIG_FILE}"
  exit 0
fi

need_cmd dig curl nc awk grep sed tr

cluster_domain="${CLUSTER_NAME}.${BASE_DOMAIN}"
api_fqdn="api.${cluster_domain}"
api_int_fqdn="api-int.${cluster_domain}"
apps_test_fqdn="wildcard-preflight.apps.${cluster_domain}"
ignition_base_url="https://${api_int_fqdn}:22623"

trim_dot() { sed 's/\.$//'; }

node_fqdn() {
  local short="$1"
  echo "${short}.${cluster_domain}"
}

dig_a() {
  local name="$1"
  dig +short @"${DNS_SERVER}" "${name}" A | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true
}

dig_ptr() {
  local ip="$1"
  dig +short @"${DNS_SERVER}" -x "${ip}" PTR | trim_dot || true
}

check_a_record() {
  local fqdn="$1"
  local expected_ip="$2"
  local actual
  actual="$(dig_a "${fqdn}" | head -n1)"
  if [[ "${actual}" == "${expected_ip}" ]]; then
    pass "A record ${fqdn} -> ${expected_ip}"
  else
    fail "A record ${fqdn} expected ${expected_ip}, got '${actual:-<none>}'"
  fi
}

check_ptr_contains() {
  local ip="$1"
  local expected_name="$2"
  local actual
  actual="$(dig_ptr "${ip}")"
  if grep -Fxq "${expected_name}" <<<"${actual}"; then
    pass "PTR ${ip} contains ${expected_name}"
  else
    fail "PTR ${ip} expected ${expected_name}, got '${actual:-<none>}'"
  fi
}

check_ptr_multi_contains() {
  local ip="$1"
  shift
  local actual
  actual="$(dig_ptr "${ip}")"
  local missing=0
  local name
  for name in "$@"; do
    if grep -Fxq "${name}" <<<"${actual}"; then
      pass "PTR ${ip} contains ${name}"
    else
      fail "PTR ${ip} missing ${name}, got '${actual:-<none>}'"
      missing=1
    fi
  done
  return "${missing}"
}

tcp_check() {
  local host="$1"
  local port="$2"
  if nc -z -w3 "${host}" "${port}" >/dev/null 2>&1; then
    pass "TCP ${host}:${port} reachable"
  else
    fail "TCP ${host}:${port} not reachable"
  fi
}

http_check() {
  local url="$1"
  local label="$2"
  local curl_args=(
    -fsS
    --connect-timeout 5
    --max-time 20
    -o /dev/null
    -w '%{http_code}'
  )

  if [[ "${url}" =~ ^https://[^/]+:22623/ ]]; then
    curl_args+=(-k)
  fi

  local status
  if ! status="$(curl "${curl_args[@]}" "${url}" 2>/dev/null)"; then
    fail "${label} not reachable: ${url}"
    return
  fi

  if [[ "${status}" =~ ^2[0-9][0-9]$ ]]; then
    pass "${label} reachable: ${url} (HTTP ${status})"
  else
    fail "${label} returned HTTP ${status}: ${url}"
  fi
}

fetch_text() {
  local src="$1"
  if [[ "${src}" =~ ^https?:// ]]; then
    curl -fsSL --connect-timeout 5 --max-time 20 "${src}"
  else
    cat "${src}"
  fi
}

check_url_reachable() {
  local url="$1"
  if curl -fsSIL --connect-timeout 5 --max-time 20 "${url}" >/dev/null 2>&1; then
    pass "Artifact reachable: ${url}"
  else
    fail "Artifact not reachable: ${url}"
  fi
}

extract_urls() {
  grep -Eo 'https?://[^[:space:]"]+' | sed 's/[),;]$//' | sort -u
}

ssh_lb() {
  ssh -o BatchMode=yes -o ConnectTimeout=5 "${LB_SSH_USER}@${LB_HOST}" "$@"
}

backend_section() {
  local cfg="$1"
  local backend="$2"
  awk -v backend="${backend}" '
    $1 == "backend" {
      if (in_backend) {
        exit
      }
      in_backend = ($2 == backend)
      next
    }
    in_backend {
      print
    }
  ' <<<"${cfg}"
}

backend_has_server_port() {
  local cfg="$1"
  local backend="$2"
  local host="$3"
  local port="$4"
  local section
  section="$(backend_section "${cfg}" "${backend}")"
  [[ -n "${section}" ]] || return 1
  grep -Eiq "server[[:space:]].*(${host}|${host//./\\.}).*:${port}([[:space:]]|$)" <<<"${section}"
}

check_lb_listeners() {
  local listeners
  if ! listeners="$(ssh_lb "sudo ss -lntH | awk '{print \$4}'" 2>/dev/null)"; then
    warn "Could not inspect load balancer listeners over SSH from ${LB_HOST}; skipping listener checks"
    return 0
  fi

  local port
  for port in 6443 22623 80 443; do
    if grep -Eq "[:.]${port}$" <<<"${listeners}"; then
      pass "Load balancer is listening on ${port}"
    else
      fail "Load balancer is not listening on ${port}"
    fi
  done
}

check_lb_config() {
  local cfg
  if ! cfg="$(ssh_lb "sudo cat '${HAPROXY_CFG}'" 2>/dev/null)"; then
    warn "Could not read HAProxy config over SSH from ${LB_HOST}; skipping backend membership checks"
    return 0
  fi

  if grep -Eq '/readyz' <<<"${cfg}"; then
    pass "HAProxy config includes /readyz health check for API"
  else
    warn "HAProxy config does not show /readyz health check for API"
  fi

  local b_short b_fqdn
  b_short="$(tuple_name "${BOOTSTRAP_NODE}")"
  b_fqdn="$(node_fqdn "${b_short}")"

  local tuple short fqdn

  for tuple in "${MASTER_NODES[@]}"; do
    short="$(tuple_name "${tuple}")"
    fqdn="$(node_fqdn "${short}")"

    if backend_has_server_port "${cfg}" "api_backend" "${short}" 6443 || backend_has_server_port "${cfg}" "api_backend" "${fqdn}" 6443; then
      pass "LB config includes ${short} on 6443"
    else
      fail "LB config missing ${short} on 6443"
    fi

    if backend_has_server_port "${cfg}" "machine_config_backend" "${short}" 22623 || backend_has_server_port "${cfg}" "machine_config_backend" "${fqdn}" 22623; then
      pass "LB config includes ${short} on 22623"
    else
      fail "LB config missing ${short} on 22623"
    fi
  done

  if [[ "${PHASE}" == "pre-bootstrap" ]]; then
    if backend_has_server_port "${cfg}" "api_backend" "${b_short}" 6443 || backend_has_server_port "${cfg}" "api_backend" "${b_fqdn}" 6443; then
      pass "Pre-bootstrap LB config includes bootstrap on 6443"
    else
      fail "Pre-bootstrap LB config missing bootstrap on 6443"
    fi

    if backend_has_server_port "${cfg}" "machine_config_backend" "${b_short}" 22623 || backend_has_server_port "${cfg}" "machine_config_backend" "${b_fqdn}" 22623; then
      pass "Pre-bootstrap LB config includes bootstrap on 22623"
    else
      fail "Pre-bootstrap LB config missing bootstrap on 22623"
    fi
  else
    if backend_has_server_port "${cfg}" "api_backend" "${b_short}" 6443 || backend_has_server_port "${cfg}" "api_backend" "${b_fqdn}" 6443; then
      fail "Post-bootstrap LB config still includes bootstrap on 6443"
    else
      pass "Post-bootstrap LB config has bootstrap removed from 6443"
    fi

    if backend_has_server_port "${cfg}" "machine_config_backend" "${b_short}" 22623 || backend_has_server_port "${cfg}" "machine_config_backend" "${b_fqdn}" 22623; then
      fail "Post-bootstrap LB config still includes bootstrap on 22623"
    else
      pass "Post-bootstrap LB config has bootstrap removed from 22623"
    fi
  fi

  for tuple in "${INGRESS_NODES[@]}"; do
    short="$(tuple_name "${tuple}")"
    fqdn="$(node_fqdn "${short}")"

    if backend_has_server_port "${cfg}" "ingress_http" "${short}" 80 || backend_has_server_port "${cfg}" "ingress_http" "${fqdn}" 80; then
      pass "LB config includes ${short} on 80"
    else
      fail "LB config missing ${short} on 80"
    fi

    if backend_has_server_port "${cfg}" "ingress_https" "${short}" 443 || backend_has_server_port "${cfg}" "ingress_https" "${fqdn}" 443; then
      pass "LB config includes ${short} on 443"
    else
      fail "LB config missing ${short} on 443"
    fi
  done
}

check_boot_artifact() {
  local src="$1"
  local content
  if ! content="$(fetch_text "${src}" 2>/dev/null)"; then
    fail "Could not read boot artifact: ${src}"
    return
  fi

  pass "Read boot artifact: ${src}"

  local effective_method="${BOOT_METHOD}"
  if grep -q '^#!ipxe' <<<"${content}"; then
    effective_method="ipxe"
  fi

  if grep -q 'coreos.live.rootfs_url=' <<<"${content}"; then
    pass "${src}: has coreos.live.rootfs_url"
  else
    fail "${src}: missing coreos.live.rootfs_url"
  fi

  if grep -q 'coreos.inst.ignition_url=' <<<"${content}"; then
    pass "${src}: has coreos.inst.ignition_url"
  else
    fail "${src}: missing coreos.inst.ignition_url"
  fi

  if grep -q 'coreos.inst.install_dev=' <<<"${content}"; then
    pass "${src}: has coreos.inst.install_dev"
  else
    fail "${src}: missing coreos.inst.install_dev"
  fi

  if [[ -n "${EXPECT_INSTALL_DEV:-}" ]]; then
    if grep -q "coreos.inst.install_dev=${EXPECT_INSTALL_DEV}" <<<"${content}"; then
      pass "${src}: install device matches ${EXPECT_INSTALL_DEV}"
    else
      fail "${src}: install device does not match ${EXPECT_INSTALL_DEV}"
    fi
  fi

  if [[ "${effective_method}" == "ipxe" ]]; then
    if grep -q 'initrd=main' <<<"${content}"; then
      pass "${src}: has initrd=main for UEFI iPXE"
    else
      fail "${src}: missing initrd=main for UEFI iPXE"
    fi
  fi

  if [[ "${REQUIRE_PINNED_NIC:-no}" == "yes" ]]; then
    if grep -q "ip=${EXPECT_BOOT_NIC}:dhcp" <<<"${content}"; then
      pass "${src}: pinned NIC is ${EXPECT_BOOT_NIC}"
    else
      fail "${src}: missing pinned NIC argument ip=${EXPECT_BOOT_NIC}:dhcp"
    fi
  fi

  local url
  while read -r url; do
    [[ -z "${url}" ]] && continue
    check_url_reachable "${url}"
  done < <(extract_urls <<<"${content}")
}

check_ignition_endpoints() {
  local role
  for role in master worker; do
    http_check "${ignition_base_url}/config/${role}" "Ignition endpoint for ${role}"
  done
}

echo
info "Cluster domain: ${cluster_domain}"
info "Phase: ${PHASE}"
info "DNS server: ${DNS_SERVER}"
echo

check_a_record "${api_fqdn}" "${API_VIP}"
check_a_record "${api_int_fqdn}" "${API_VIP}"
check_a_record "${apps_test_fqdn}" "${INGRESS_VIP}"

check_ptr_multi_contains "${API_VIP}" "${api_fqdn}" "${api_int_fqdn}"

check_a_record "$(node_fqdn "$(tuple_name "${BOOTSTRAP_NODE}")")" "$(tuple_ip "${BOOTSTRAP_NODE}")"
check_ptr_contains "$(tuple_ip "${BOOTSTRAP_NODE}")" "$(node_fqdn "$(tuple_name "${BOOTSTRAP_NODE}")")"

for tuple in "${MASTER_NODES[@]}"; do
  check_a_record "$(node_fqdn "$(tuple_name "${tuple}")")" "$(tuple_ip "${tuple}")"
  check_ptr_contains "$(tuple_ip "${tuple}")" "$(node_fqdn "$(tuple_name "${tuple}")")"
done

for tuple in "${WORKER_NODES[@]}"; do
  check_a_record "$(node_fqdn "$(tuple_name "${tuple}")")" "$(tuple_ip "${tuple}")"
  check_ptr_contains "$(tuple_ip "${tuple}")" "$(node_fqdn "$(tuple_name "${tuple}")")"
done

echo
info "Checking VIP listener reachability from the installer workstation"
tcp_check "${API_VIP}" 6443
tcp_check "${API_VIP}" 22623
tcp_check "${INGRESS_VIP}" 80
tcp_check "${INGRESS_VIP}" 443

echo
info "Checking ignition endpoints"
check_ignition_endpoints

echo
if [[ "${ENABLE_LB_SSH_CHECK:-no}" == "yes" ]]; then
  info "Checking load balancer config and listeners over SSH"
  need_cmd ssh
  check_lb_listeners
  check_lb_config
else
  warn "LB SSH checks disabled"
fi

echo
if [[ "${ENABLE_BOOT_ARTIFACT_CHECK:-no}" == "yes" ]]; then
  info "Checking boot artifacts"
  for artifact in "${BOOT_ARTIFACTS[@]}"; do
    check_boot_artifact "${artifact}"
  done
else
  warn "Boot artifact checks disabled"
fi

echo
echo "========================"
echo "Preflight summary"
echo "========================"
echo "PASS: ${PASS_COUNT}"
echo "WARN: ${WARN_COUNT}"
echo "FAIL: ${FAIL_COUNT}"

if (( FAIL_COUNT > 0 )); then
  exit 1
fi
