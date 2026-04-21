#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TARGET_SCRIPT="${REPO_ROOT}/ocp-preflight.sh"

TEST_TMP=''
TESTS_RUN=0
TESTS_FAILED=0
RUN_SCRIPT_PATH=''
MOCK_SSH_CAT_FAIL='no'
MOCK_SSH_SS_FAIL='no'

cleanup() {
  if [[ -n "${TEST_TMP}" && -d "${TEST_TMP}" ]]; then
    rm -rf "${TEST_TMP}"
  fi
}

trap cleanup EXIT

setup_test_env() {
  cleanup
  TEST_TMP="$(mktemp -d)"
  mkdir -p "${TEST_TMP}/bin"
  RUN_SCRIPT_PATH="${TEST_TMP}/bin:${PATH}"
  MOCK_SSH_CAT_FAIL='no'
  MOCK_SSH_SS_FAIL='no'
  write_mock_commands
}

write_mock_commands() {
  cat > "${TEST_TMP}/bin/dig" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

args=("$@")

if [[ " $* " == *" -x "* ]]; then
  ip=''
  for ((i=0; i<${#args[@]}; i+=1)); do
    if [[ "${args[i]}" == "-x" && $((i + 1)) -lt ${#args[@]} ]]; then
      ip="${args[i + 1]}"
      break
    fi
  done

  case "${ip}" in
    192.168.10.20)
      printf '%s\n' \
        "api.ocp01.lab.example.com." \
        "api-int.ocp01.lab.example.com."
      ;;
    192.168.10.30) echo "bootstrap.ocp01.lab.example.com." ;;
    192.168.10.31) echo "master0.ocp01.lab.example.com." ;;
    192.168.10.32) echo "master1.ocp01.lab.example.com." ;;
    192.168.10.33) echo "master2.ocp01.lab.example.com." ;;
    192.168.10.41) echo "worker0.ocp01.lab.example.com." ;;
    192.168.10.42) echo "worker1.ocp01.lab.example.com." ;;
  esac
  exit 0
fi

name=''
for arg in "${args[@]}"; do
  case "${arg}" in
    @*|+short|A|PTR) ;;
    *)
      name="${arg}"
      ;;
  esac
done

case "${name}" in
  api.ocp01.lab.example.com|api-int.ocp01.lab.example.com)
    echo "192.168.10.20"
    ;;
  wildcard-preflight.apps.ocp01.lab.example.com)
    echo "192.168.10.21"
    ;;
  bootstrap.ocp01.lab.example.com)
    echo "192.168.10.30"
    ;;
  master0.ocp01.lab.example.com)
    echo "192.168.10.31"
    ;;
  master1.ocp01.lab.example.com)
    echo "192.168.10.32"
    ;;
  master2.ocp01.lab.example.com)
    echo "192.168.10.33"
    ;;
  worker0.ocp01.lab.example.com)
    echo "192.168.10.41"
    ;;
  worker1.ocp01.lab.example.com)
    echo "192.168.10.42"
    ;;
esac
EOF
  chmod +x "${TEST_TMP}/bin/dig"

  cat > "${TEST_TMP}/bin/nc" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "${TEST_TMP}/bin/nc"

  cat > "${TEST_TMP}/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

url="${*: -1}"

if [[ " $* " == *" -w "* ]]; then
  if [[ "${url}" == *"/config/master" || "${url}" == *"/config/worker" ]]; then
    printf '200'
    exit 0
  fi
  printf '404'
  exit 0
fi

if [[ " $* " == *" -I "* || " $* " == *" -I"* || " $* " == *" -IL "* || " $* " == *" -SIL "* ]]; then
  exit 0
fi

if [[ "${url}" =~ ^https?:// ]]; then
  cat "${MOCK_HTTP_BODY_FILE}"
  exit 0
fi

exit 0
EOF
  chmod +x "${TEST_TMP}/bin/curl"

  cat > "${TEST_TMP}/bin/ssh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

remote_cmd="${*: -1}"

if [[ "${remote_cmd}" == *"sudo cat"* ]]; then
  if [[ "${MOCK_SSH_CAT_FAIL:-no}" == "yes" ]]; then
    exit 1
  fi
  cat "${MOCK_HAPROXY_CFG_FILE}"
  exit 0
fi

if [[ "${remote_cmd}" == *"ss -lntH"* ]]; then
  if [[ "${MOCK_SSH_SS_FAIL:-no}" == "yes" ]]; then
    exit 1
  fi
  printf '%s\n' \
    "0.0.0.0:6443" \
    "0.0.0.0:22623" \
    "0.0.0.0:80" \
    "0.0.0.0:443"
  exit 0
fi

exit 1
EOF
  chmod +x "${TEST_TMP}/bin/ssh"
}

write_config() {
  local path="$1"
  local phase="$2"
  local enable_lb="${3:-yes}"
  local lb_enabled='true'

  if [[ "${enable_lb}" != "yes" ]]; then
    lb_enabled='false'
  fi

  cat > "${path}" <<EOF
phase: ${phase}
dns_server: 192.168.10.53
cluster_name: ocp01
base_domain: lab.example.com
api_vip: 192.168.10.20
ingress_vip: 192.168.10.21
bootstrap_node:
  name: bootstrap
  ip: 192.168.10.30
master_nodes:
  - name: master0
    ip: 192.168.10.31
  - name: master1
    ip: 192.168.10.32
  - name: master2
    ip: 192.168.10.33
worker_nodes:
  - name: worker0
    ip: 192.168.10.41
  - name: worker1
    ip: 192.168.10.42
ingress_role: workers
load_balancer:
  enabled: ${lb_enabled}
  host: lb01.lab.example.com
  ssh_user: core
  haproxy_cfg: /etc/haproxy/haproxy.cfg
boot_artifacts:
  enabled: false
EOF
}

write_haproxy_cfg() {
  local path="$1"
  local phase="$2"
  if [[ "${phase}" == "pre-bootstrap" ]]; then
    cat > "${path}" <<'EOF'
backend api_backend
  option httpchk GET /readyz
  server bootstrap bootstrap.ocp01.lab.example.com:6443 check
  server master0 master0.ocp01.lab.example.com:6443 check
  server master1 master1.ocp01.lab.example.com:6443 check
  server master2 master2.ocp01.lab.example.com:6443 check

backend machine_config_backend
  server bootstrap bootstrap.ocp01.lab.example.com:22623 check
  server master0 master0.ocp01.lab.example.com:22623 check
  server master1 master1.ocp01.lab.example.com:22623 check
  server master2 master2.ocp01.lab.example.com:22623 check

backend ingress_http
  server worker0 worker0.ocp01.lab.example.com:80 check
  server worker1 worker1.ocp01.lab.example.com:80 check

backend ingress_https
  server worker0 worker0.ocp01.lab.example.com:443 check
  server worker1 worker1.ocp01.lab.example.com:443 check
EOF
  else
    cat > "${path}" <<'EOF'
backend api_backend
  option httpchk GET /readyz
  server master0 master0.ocp01.lab.example.com:6443 check
  server master1 master1.ocp01.lab.example.com:6443 check
  server master2 master2.ocp01.lab.example.com:6443 check

backend machine_config_backend
  server master0 master0.ocp01.lab.example.com:22623 check
  server master1 master1.ocp01.lab.example.com:22623 check
  server master2 master2.ocp01.lab.example.com:22623 check

backend ingress_http
  server worker0 worker0.ocp01.lab.example.com:80 check
  server worker1 worker1.ocp01.lab.example.com:80 check

backend ingress_https
  server worker0 worker0.ocp01.lab.example.com:443 check
  server worker1 worker1.ocp01.lab.example.com:443 check
EOF
  fi
}

run_script() {
  local output_file="$1"
  shift

  local status=0
  PATH="${RUN_SCRIPT_PATH}" \
    MOCK_HAPROXY_CFG_FILE="${TEST_TMP}/haproxy.cfg" \
    MOCK_HTTP_BODY_FILE="${TEST_TMP}/http-body.txt" \
    MOCK_SSH_CAT_FAIL="${MOCK_SSH_CAT_FAIL}" \
    MOCK_SSH_SS_FAIL="${MOCK_SSH_SS_FAIL}" \
    bash "${TARGET_SCRIPT}" "$@" >"${output_file}" 2>&1 || status=$?

  echo "${status}"
}

assert_exit_code() {
  local actual="$1"
  local expected="$2"
  local context="$3"
  if [[ "${actual}" != "${expected}" ]]; then
    echo "ASSERTION FAILED: ${context} expected exit ${expected}, got ${actual}"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

assert_contains() {
  local file="$1"
  local expected="$2"
  local context="$3"
  if ! grep -Fq "${expected}" "${file}"; then
    echo "ASSERTION FAILED: ${context} missing '${expected}'"
    echo "----- output -----"
    cat "${file}"
    echo "------------------"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

assert_not_contains() {
  local file="$1"
  local unexpected="$2"
  local context="$3"
  if grep -Fq "${unexpected}" "${file}"; then
    echo "ASSERTION FAILED: ${context} unexpectedly found '${unexpected}'"
    echo "----- output -----"
    cat "${file}"
    echo "------------------"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

run_test() {
  local name="$1"
  shift
  TESTS_RUN=$((TESTS_RUN + 1))
  echo "Running: ${name}"
  "$@"
}

test_validate_config_success() {
  setup_test_env
  : > "${TEST_TMP}/http-body.txt"
  write_config "${TEST_TMP}/config.yaml" "pre-bootstrap" "no"
  write_haproxy_cfg "${TEST_TMP}/haproxy.cfg" "pre-bootstrap"

  local output="${TEST_TMP}/output.txt"
  local status
  status="$(run_script "${output}" --validate-config "${TEST_TMP}/config.yaml")"

  assert_exit_code "${status}" "0" "validate-config success"
  assert_contains "${output}" "[INFO] Configuration is valid: ${TEST_TMP}/config.yaml" "validate-config success"
}

test_validate_config_does_not_require_runtime_commands() {
  setup_test_env
  : > "${TEST_TMP}/http-body.txt"
  write_config "${TEST_TMP}/config.yaml" "pre-bootstrap" "no"
  write_haproxy_cfg "${TEST_TMP}/haproxy.cfg" "pre-bootstrap"

  mkdir -p "${TEST_TMP}/yaml-only-bin"
  ln -s "$(command -v bash)" "${TEST_TMP}/yaml-only-bin/bash"
  ln -s "$(command -v python3)" "${TEST_TMP}/yaml-only-bin/python3"
  ln -s "$(command -v mktemp)" "${TEST_TMP}/yaml-only-bin/mktemp"
  ln -s "$(command -v rm)" "${TEST_TMP}/yaml-only-bin/rm"
  RUN_SCRIPT_PATH="${TEST_TMP}/yaml-only-bin"

  local output="${TEST_TMP}/output.txt"
  local status
  status="$(run_script "${output}" --validate-config "${TEST_TMP}/config.yaml")"

  assert_exit_code "${status}" "0" "validate-config without runtime commands"
  assert_contains "${output}" "[INFO] Configuration is valid: ${TEST_TMP}/config.yaml" "validate-config without runtime commands"
  assert_not_contains "${output}" "required command not found" "validate-config without runtime commands"
}

test_shell_config_is_rejected() {
  setup_test_env
  : > "${TEST_TMP}/http-body.txt"
  cat > "${TEST_TMP}/config.conf" <<'EOF'
PHASE="pre-bootstrap"
DNS_SERVER="192.168.10.53"
EOF

  local output="${TEST_TMP}/output.txt"
  local status
  status="$(run_script "${output}" --validate-config "${TEST_TMP}/config.conf")"

  assert_exit_code "${status}" "2" "shell config is rejected"
  assert_contains "${output}" "ERROR: could not parse YAML config ${TEST_TMP}/config.conf:" "shell config is rejected"
}

test_validate_config_rejects_invalid_phase() {
  setup_test_env
  : > "${TEST_TMP}/http-body.txt"
  write_config "${TEST_TMP}/config.yaml" "during-install" "no"
  write_haproxy_cfg "${TEST_TMP}/haproxy.cfg" "pre-bootstrap"

  local output="${TEST_TMP}/output.txt"
  local status
  status="$(run_script "${output}" --validate-config "${TEST_TMP}/config.yaml")"

  assert_exit_code "${status}" "2" "invalid phase config"
  assert_contains "${output}" "ERROR: PHASE must be 'pre-bootstrap' or 'post-bootstrap', got 'during-install'" "invalid phase config"
}

test_validate_config_rejects_missing_lb_host() {
  setup_test_env
  : > "${TEST_TMP}/http-body.txt"
  write_config "${TEST_TMP}/config.yaml" "pre-bootstrap" "yes"
  write_haproxy_cfg "${TEST_TMP}/haproxy.cfg" "pre-bootstrap"
  sed -i 's/^  host: .*/  host: ""/' "${TEST_TMP}/config.yaml"

  local output="${TEST_TMP}/output.txt"
  local status
  status="$(run_script "${output}" --validate-config "${TEST_TMP}/config.yaml")"

  assert_exit_code "${status}" "2" "missing lb host"
  assert_contains "${output}" "ERROR: required config value is empty: LB_HOST" "missing lb host"
}

test_pre_bootstrap_lb_logic() {
  setup_test_env
  : > "${TEST_TMP}/http-body.txt"
  write_config "${TEST_TMP}/config.yaml" "pre-bootstrap" "yes"
  write_haproxy_cfg "${TEST_TMP}/haproxy.cfg" "pre-bootstrap"

  local output="${TEST_TMP}/output.txt"
  local status
  status="$(run_script "${output}" "${TEST_TMP}/config.yaml")"

  assert_exit_code "${status}" "0" "pre-bootstrap run"
  assert_contains "${output}" "[PASS] Pre-bootstrap LB config includes bootstrap on 6443" "pre-bootstrap lb membership"
  assert_contains "${output}" "[PASS] Pre-bootstrap LB config includes bootstrap on 22623" "pre-bootstrap lb membership"
  assert_contains "${output}" "FAIL: 0" "pre-bootstrap summary"
}

test_lb_listener_checks_run_when_config_read_fails() {
  setup_test_env
  : > "${TEST_TMP}/http-body.txt"
  write_config "${TEST_TMP}/config.yaml" "pre-bootstrap" "yes"
  write_haproxy_cfg "${TEST_TMP}/haproxy.cfg" "pre-bootstrap"
  MOCK_SSH_CAT_FAIL='yes'

  local output="${TEST_TMP}/output.txt"
  local status
  status="$(run_script "${output}" "${TEST_TMP}/config.yaml")"

  assert_exit_code "${status}" "0" "lb listeners still run when config read fails"
  assert_contains "${output}" "[PASS] Load balancer is listening on 6443" "lb listeners still run when config read fails"
  assert_contains "${output}" "[PASS] Load balancer is listening on 22623" "lb listeners still run when config read fails"
  assert_contains "${output}" "[WARN] Could not read HAProxy config over SSH from lb01.lab.example.com; skipping backend membership checks" "lb listeners still run when config read fails"
  assert_contains "${output}" "FAIL: 0" "lb listeners still run when config read fails"
}

test_lb_backend_membership_requires_correct_backends() {
  setup_test_env
  : > "${TEST_TMP}/http-body.txt"
  write_config "${TEST_TMP}/config.yaml" "pre-bootstrap" "yes"
  cat > "${TEST_TMP}/haproxy.cfg" <<'EOF'
backend not_api
  option httpchk GET /readyz
  server bootstrap bootstrap.ocp01.lab.example.com:6443 check
  server master0 master0.ocp01.lab.example.com:6443 check
  server master1 master1.ocp01.lab.example.com:6443 check
  server master2 master2.ocp01.lab.example.com:6443 check
  server worker0 worker0.ocp01.lab.example.com:80 check
  server worker1 worker1.ocp01.lab.example.com:80 check

backend not_machine_config
  server bootstrap bootstrap.ocp01.lab.example.com:22623 check
  server master0 master0.ocp01.lab.example.com:22623 check
  server master1 master1.ocp01.lab.example.com:22623 check
  server master2 master2.ocp01.lab.example.com:22623 check
  server worker0 worker0.ocp01.lab.example.com:443 check
  server worker1 worker1.ocp01.lab.example.com:443 check
EOF

  local output="${TEST_TMP}/output.txt"
  local status
  status="$(run_script "${output}" "${TEST_TMP}/config.yaml")"

  assert_exit_code "${status}" "1" "lb backend membership requires correct backends"
  assert_contains "${output}" "[FAIL] LB config missing master0 on 6443" "lb backend membership requires correct backends"
  assert_contains "${output}" "[FAIL] LB config missing worker0 on 80" "lb backend membership requires correct backends"
}

test_post_bootstrap_lb_logic() {
  setup_test_env
  : > "${TEST_TMP}/http-body.txt"
  write_config "${TEST_TMP}/config.yaml" "post-bootstrap" "yes"
  write_haproxy_cfg "${TEST_TMP}/haproxy.cfg" "post-bootstrap"

  local output="${TEST_TMP}/output.txt"
  local status
  status="$(run_script "${output}" "${TEST_TMP}/config.yaml")"

  assert_exit_code "${status}" "0" "post-bootstrap run"
  assert_contains "${output}" "[PASS] Post-bootstrap LB config has bootstrap removed from 6443" "post-bootstrap lb membership"
  assert_contains "${output}" "[PASS] Post-bootstrap LB config has bootstrap removed from 22623" "post-bootstrap lb membership"
  assert_contains "${output}" "FAIL: 0" "post-bootstrap summary"
}

main() {
  run_test "validate config succeeds" test_validate_config_success
  run_test "validate-only skips runtime command dependencies" test_validate_config_does_not_require_runtime_commands
  run_test "legacy shell config is rejected" test_shell_config_is_rejected
  run_test "invalid phase is rejected" test_validate_config_rejects_invalid_phase
  run_test "missing LB host is rejected" test_validate_config_rejects_missing_lb_host
  run_test "pre-bootstrap LB membership passes" test_pre_bootstrap_lb_logic
  run_test "LB listeners still run if config read fails" test_lb_listener_checks_run_when_config_read_fails
  run_test "LB membership is backend-aware" test_lb_backend_membership_requires_correct_backends
  run_test "post-bootstrap LB membership passes" test_post_bootstrap_lb_logic

  echo
  echo "Tests run: ${TESTS_RUN}"
  echo "Failures: ${TESTS_FAILED}"

  if (( TESTS_FAILED > 0 )); then
    exit 1
  fi
}

main "$@"
