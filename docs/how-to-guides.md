# How to reproducibly report a cURL vulnerability with NICE

This guide provides instructions on how to create a new vulnerability report for a cURL vulnerability using the NICE framework.

## Getting Started

Start by cloning the NICE cURL vulnerability reporter repository and run the `nice-report.py` script. Select the "Create new security report" option. This will guide you through a series of questions to gather the necessary information for the report. The script will then generate a new directory under `reports/` with a template `report.yaml` file that you can edit to add the details of the vulnerability.

## Report Structure

NICE cURL vulnerability reports is basically a declarative description of the vulnerability, with three main components:
1) `curl` details: package information and configuration options.
2) Environment details: description of the environment (NICE uses VMs to simulate the environment). Specifies which kind of services are running on the client, server, or custom VMs, and how they are networked together.
3) Test scenarios: a sequence of actions to be performed on the environment, and assertions to check whether the vulnerability is successfully exploited. This test can also be viewed as instructions or step to reproduce the vulnerability but able to be automatically executed by the NICE framework.

### Get `curl` details

It is important to specify the exact version of `curl` that is vulnerable, and the configuration options used to build it.

There are three strategies to specify the `curl` details:
- `nixpkgs`: Fetch the `curl` package from Nixpkgs. This is the recommended way if there are no or very simple specific configuration options needed.
- `source`: Build `curl` from source code. This fetches the source code from the specified URL and builds it with the specified configuration options.
- `custom`: Provide a custom Nix expression to build the `curl` package. See details in [Customize `curl` build](./nix-guides.md#customize-curl-build).

Nix approach values reproducibility and transparency, so it requires the exact version and hash of the `curl` package to be predefined. The provided CLI tool can help you fetch the correct hash for the `curl` version automatically after the report template is generated or whenever you select the "Update hashes for existing report" option in the CLI tool.

```yaml
curl:
    strategy: nixpkgs
    package:
        version: 8.3.0
        commit: <commit-hash> # will be automatically filled by the CLI tool
        sha256: <sha256-hash> # will be automatically filled by the CLI tool
```

Configure build options can also be added using YAML's fields under `package`. Check the [NICE YAML documentation](./documentation.md) for the full list of supported configuration options.

### Describe the environment

The next step is to describe the VMs and how they interact with each other. There are 3 types of attack patterns for curl vulnerabilities in the current version of NICE:
- `remote`: set up 2 VMs, one for the `client` with the vulnerable `curl` and one for the `attacker`. The attacker VM simulates a malicious server that the client VM interacts with to trigger the vulnerability.
- `local`: set up 1 VM with the vulnerable `curl` installed. The attack is triggered locally on the `client` VM without the need of an attacker VM.
- `custom`: no predefined VM setup. 

Additional VMs can be added if needed, under the `custom_vms` field. 

All VM should be able to turn on/off Internet access with `internet_access: true/false` field. This can be useful to simulate vulnerabilities that require Internet access but it might reduce the reproducibility of the report since it depends on external, uncontrollable factors (e.g. the link might not be available in the future). It is recommended to set up a local server on the attacker VM or a custom VM to simulate the Internet service.

Refer to the above documentation for the configuration of the VMs. If more services are needed, you can add them in `vm-configs/` and create new VM configurations. See (Nix Guides)[./nix-guides.md] for more details on how to customize the VM configurations.

#### 1. Client VM

The client VM is the one that has the vulnerable `curl` installed. In very scenario, it will be the one to trigger the vulnerability. Depending on the attack pattern and vulnerability target, different services can be set up on the client VM:

- If the vulnerability targets libcurl, you can specify the `application` field to set up a service that uses libcurl.

#### 2. Attacker VM

Only available for the `remote` attack pattern. The attacker VM simulates a malicious server that the client VM interacts with to trigger the vulnerability.

- You can specify the `networking.allowed_tcp_ports` field to open specific TCP ports on the attacker VM.

```yaml
...
vm:
    attack_pattern: remote
    attacker:
        networking:
            allowed_tcp_ports: [ <port1>, <port2>, ... ] # or just <port> if only one port is needed
```

- You can specify the `server` field to set up a dedicated attacker server. Only `C` and `Python` servers are supported in the current version. You can put the exploit source code in the `exploit/server/` directory and specify the build and run commands and configuration in the `report.yaml` file. An example of a simple C server from [CVE-2023-38039](../reports/cve-2023-38039-curl-no-large-headers-limit-oom/report.yaml):

```yaml
...
    server:
        file_path: ./exploit/server
        language: c
        build_config:
            build_inputs: gcc            
            build_commands: gcc -o exploit exploit.c
            build_output: exploit
        run_command: ./exploit
```

An Python server example of [CVE-2025-5399](../reports/cve-2025-5399-curl-ws-loop-3168039/report.yaml):

```yaml
...
    server:
        language: python
        python_version: "3.12"
        python_packages: [ pwntools ]
        run_command: python3 exploit-server.py
```

### Write test scenarios

The YAML report provides an abstract layer to the original NixOS test framework, which allows users to write test scenarios for NixOS VM. 

There are 3 main actions in the test:
- `run`: run a command on the VM. By default, the command is expected to be successful, but you can also specify `expected_status` to `failure` (with optional `expected_exit_codes`) or `any`(to ignore the result of the command).
- `wait`: wait for a specific condition to be met. This is useful when the test needs to wait for the server to be ready before running the next command.
- `assert`: the most important piece of the test, which checks whether the vulnerability is successfully exploited or an expected behavior is observed. It is the evidence of the vulnerability and the key part of the report.

Let's take an example from [CVE-2023-38545](../reports/cve-2023-38545-curl-socks5-overflow/report.yaml) (see details [report](https://hackerone.com/reports/2187833)). In short, this flaw makes curl overflow a heap based buffer when processing a SOCKS5 proxy handshake. The attacker when need to control a hostname (proxy) so that the vulnerable client follows the redirect.

So the flow is: execute the curl command -> check if an overflow (coredump) happens. We also need to wait for certain services to happen before actually running the curl command (except for the attacker server, which is waited by default). The test scenario can be written as:

```yaml
test_script:
  - wait:
      machine: proxy
      type: "service"
      service_name: "sshSOCKS5Proxy.service"
  - wait:
      machine: proxy
      type: "port"
      port: 10801
  - run:
      machine: client
      expected_status: failure
      expected_exit_codes: [ 134, 1 ]
      command: curl -L --limit-rate 32768 -x socks5h://proxy:10801 attacker:8000 2>&1
  - assert:
      name: check-core-dump-exists
      machine: client
      params:
        expected_signal: ABRT
```

You can rewrite the test scenarios with a `test-script.py` file but it is recommended to use the YAML report file for better readability and maintainability. Check the [NICE YAML documentation](./documentation.md) for the full list of supported actions and assertions, and how to use them. If you need to write custom test logic that is not supported by the YAML report, refer to the [Nix Guides](./nix-guides.md).