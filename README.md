# OCP Preflight

`ocp_preflight` is a Bash-based validation script for OpenShift bare-metal or PXE/iPXE-driven installs. It performs preflight checks against the infrastructure that an OpenShift cluster depends on before or during installation.

The repository currently contains:

- `ocp-preflight.sh`: the main preflight script
- `ocp-preflight.conf`: environment-specific configuration consumed by the script
- `README.md`: project documentation

## What It Validates

The script validates several pieces of install readiness:

- Forward DNS records for the API VIP, `api-int`, bootstrap, masters, and workers
- Wildcard apps DNS resolution using `wildcard-preflight.apps.<cluster domain>`
- Reverse DNS records for the API VIP, bootstrap, masters, and workers
- TCP reachability to:
  - API VIP on `6443`
  - API VIP on `22623`
  - Ingress VIP on `80`
  - Ingress VIP on `443`
- Ignition endpoint reachability on `api-int.<cluster domain>:22623` for:
  - `/config/master`
  - `/config/worker`
- Optional load balancer checks over SSH:
  - HAProxy listener ports
  - backend membership for masters, bootstrap, and ingress nodes
  - bootstrap inclusion or removal based on install phase
  - presence of `/readyz` health checks
- Optional boot artifact inspection:
  - artifact accessibility
  - required kernel arguments such as `coreos.live.rootfs_url`
  - `coreos.inst.ignition_url`
  - `coreos.inst.install_dev`
  - pinned boot NIC arguments for multi-NIC systems
  - referenced HTTP/HTTPS artifact URL reachability

## How It Works

The script:

1. Loads a configuration file, defaulting to `./ocp-preflight.conf`
2. Validates shell syntax and required config values before running checks
3. Verifies required local commands are installed
4. Builds expected cluster FQDNs from `CLUSTER_NAME` and `BASE_DOMAIN`
5. Executes checks and prints `[PASS]`, `[WARN]`, and `[FAIL]` results
6. Prints a summary and exits non-zero if any failures occurred

Exit codes:

- `0`: all checks passed or only warnings were generated
- `1`: at least one preflight check failed
- `2`: configuration file missing or a required command is unavailable

## Requirements

The script expects a Unix-like environment with Bash and the following commands available:

- `bash`
- `dig`
- `curl`
- `nc`
- `awk`
- `grep`
- `sed`
- `tr`

If `ENABLE_LB_SSH_CHECK="yes"`, it also requires:

- `ssh`

## Configuration

The script sources `ocp-preflight.conf`, so the config file is standard shell syntax.

### Install Phase

`PHASE` controls how the bootstrap node is validated in the load balancer:

- `pre-bootstrap`: bootstrap must still be present on `6443` and `22623`
- `post-bootstrap`: bootstrap must be removed from `6443` and `22623`

### DNS and Cluster Identity

- `DNS_SERVER`: DNS server used for `dig` lookups
- `CLUSTER_NAME`: OpenShift cluster name
- `BASE_DOMAIN`: base DNS domain

These values combine into:

- cluster domain: `<CLUSTER_NAME>.<BASE_DOMAIN>`
- API endpoint: `api.<cluster domain>`
- internal API endpoint: `api-int.<cluster domain>`
- wildcard apps probe: `wildcard-preflight.apps.<cluster domain>`

### VIPs

- `API_VIP`: expected IP for `api` and `api-int`
- `INGRESS_VIP`: expected IP for ingress validation

### Node Inventory

Nodes are declared as `shortname:ip` tuples:

- `BOOTSTRAP_NODE`
- `MASTER_NODES`
- `WORKER_NODES`

Example:

```bash
MASTER_NODES=(
  "master0:192.168.10.31"
  "master1:192.168.10.32"
  "master2:192.168.10.33"
)
```

### Ingress Backends

`INGRESS_NODES` defines which nodes should serve ports `80` and `443` on the load balancer.

Typical patterns:

- standard cluster: workers
- compact or 3-node cluster: masters

Example:

```bash
INGRESS_NODES=("${WORKER_NODES[@]}")
```

### Optional Load Balancer Checks

These settings enable and control SSH-based HAProxy validation:

- `ENABLE_LB_SSH_CHECK`
- `LB_HOST`
- `LB_SSH_USER`
- `HAPROXY_CFG`

When enabled, the script attempts to:

- SSH to the load balancer
- read the HAProxy config with `sudo cat`
- inspect listening ports with `ss -lntH`

Listener checks and backend membership checks are attempted independently.

- If HAProxy config retrieval fails, the script reports a warning and skips backend membership checks.
- If listener inspection fails, the script reports a warning and skips listener checks.

### Optional Boot Artifact Checks

These settings enable validation of PXE, iPXE, or generic boot artifacts:

- `ENABLE_BOOT_ARTIFACT_CHECK`
- `BOOT_METHOD`
- `BOOT_ARTIFACTS`
- `REQUIRE_PINNED_NIC`
- `EXPECT_BOOT_NIC`
- `EXPECT_INSTALL_DEV`

Supported `BOOT_METHOD` values in the config are:

- `ipxe`
- `pxe`
- `generic`

Behavior to know:

- If an artifact starts with `#!ipxe`, the script treats it as iPXE regardless of the configured method
- All HTTP/HTTPS URLs discovered inside a boot artifact are tested for reachability
- If `REQUIRE_PINNED_NIC="yes"`, the script expects `ip=<EXPECT_BOOT_NIC>:dhcp` to be present
- If `EXPECT_INSTALL_DEV` is set, the script verifies `coreos.inst.install_dev=<value>`

## Usage

Run with the default config file in the current directory:

```bash
bash ./ocp-preflight.sh
```

Run with a custom config file:

```bash
bash ./ocp-preflight.sh /path/to/ocp-preflight.conf
```

Run with an explicit flag:

```bash
bash ./ocp-preflight.sh --config /path/to/ocp-preflight.conf
```

Validate only, without running network checks:

```bash
bash ./ocp-preflight.sh --validate-config
```

In `--validate-config` mode, the script validates shell syntax and config values without requiring runtime tools such as `dig`, `curl`, or `nc`.

Show help:

```bash
bash ./ocp-preflight.sh --help
```

## Linting

The repository includes a GitHub Actions workflow at [lint.yml](/c:/Users/jfosn/OneDrive/Documents/work/ocp_preflight/.github/workflows/lint.yml:1) that runs on pushes to `main` and on pull requests.

It currently performs:

- `bash -n ocp-preflight.sh`
- `bash -n ocp-preflight.conf`
- `shellcheck ocp-preflight.sh`
- `bash tests/run-tests.sh`

The test runner at [run-tests.sh](/c:/Users/jfosn/OneDrive/Documents/work/ocp_preflight/tests/run-tests.sh:1) uses mocked `dig`, `curl`, `nc`, and `ssh` commands to validate:

- config parsing success and failure cases
- pre-bootstrap HAProxy membership expectations
- post-bootstrap HAProxy membership expectations

## Config Validation

Before any runtime checks execute, the script validates:

- the config file exists and has valid shell syntax
- `PHASE` is `pre-bootstrap` or `post-bootstrap`
- `DNS_SERVER`, `API_VIP`, and `INGRESS_VIP` are valid IPv4 addresses
- required top-level values are non-empty
- node entries use `shortname:ip` format
- yes or no toggles use `yes` or `no`
- load balancer settings are present when LB SSH checks are enabled
- boot artifact settings are present and valid when boot artifact checks are enabled
- `EXPECT_BOOT_NIC` is set when pinned NIC validation is enabled

## Example Output

```text
[PASS] A record wildcard-preflight.apps.ocp01.lab.example.com -> 192.168.10.21
[PASS] Ignition endpoint for master reachable: https://api-int.ocp01.lab.example.com:22623/config/master (HTTP 200)
[WARN] Could not read HAProxy config over SSH from lb01.lab.example.com; skipping backend membership checks

========================
Preflight summary
========================
PASS: 14
WARN: 1
FAIL: 0
```

## Current Repo Notes

A few implementation details are worth knowing if you plan to extend this project:

- The script is intended to be sourced with shell-style configuration, so malformed config syntax will break execution.
- DNS validation uses only the configured `DNS_SERVER`, not the system resolver.
- Ignition endpoint checks use HTTPS against `api-int.<cluster domain>:22623` and accept the endpoint certificate with `curl -k`, which is useful during early install stages.
- The ingress DNS check validates `wildcard-preflight.apps.<cluster domain>` against `INGRESS_VIP` so wildcard apps resolution is exercised directly.

## Suggested Workflow

1. Copy `ocp-preflight.conf` and tailor it to the target environment.
2. Run the script from an installer or admin workstation that has network access to the VIPs, DNS server, and load balancer.
3. Resolve any `[FAIL]` results before proceeding with installation.
4. Re-run after infrastructure changes or after the bootstrap phase transitions.
