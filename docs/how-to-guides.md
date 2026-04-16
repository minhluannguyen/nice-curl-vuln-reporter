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

There are two strategies to specify the `curl` details:
- `nixpkgs`: Fetch the `curl` package from Nixpkgs. This is the recommended way if there are no or very simple specific configuration options needed.
- `source`: Build `curl` from source code. This fetches the source code from the specified URL and builds it with the specified configuration options.

Nix approach values reproducibility and transparency, so it requires the exact version and hash of the `curl` package to be predefined. The provided CLI tool can help you fetch the correct hash for the `curl` version automatically after the report template is generated or whenever you select the "Update hashes for existing report" option in the CLI tool.

```yaml
curl:
    strategy: nixpkgs
    package:
        version: 8.3.0
        commit: <commit-hash> # will be automatically filled by the CLI tool
        sha256: <sha256-hash> # will be automatically filled by the CLI tool
```

Configure build options can also be added using YAML's fields under `package`. Check [the documentation](../README.md) for the full list of supported configuration options.

### Describe the environment

The next step is to describe the VMs and how they interact with each other. There are 3 types of attack patterns for curl vulnerabilities in the current version of NICE:
- `remote`: set up 2 VMs, one for the client with the vulnerable `curl` and one for the attacker. The attacker VM simulates a malicious server that the client VM interacts with to trigger the vulnerability.
- `local`: set up 1 VM with the vulnerable `curl` installed. The attack is triggered locally on the client VM without the need of an attacker VM.
- `custom`: no predefined VM setup. 

Additional VMs can be added if needed, under the custom_vms field. 

Refer to the above documentation for the configuration of the VMs. If more services are needed, you can add them in `vm-configs/` and create new VM configurations.


### Write test scenarios

The YAML report provides an abstract layer to the original NixOS test framework, which allows users to write test scenarios for NixOS VM. It handles the setting up of the VMs and utilizes assertion blocks to check the expected behavior of the vulnerability exploitation, allowing reviewers to easily understand the vulnerability in a more declarative way.

You can rewrite the test scenarios with a `test-script.py` file but it is recommended to use the YAML report file for better readability and maintainability. Refer to the [NixOS Testing Framework](https://nixos.wiki/wiki/NixOS_Testing_library) and [its syntax](https://nixos.org/manual/nixos/stable/index.html#sec-nixos-tests) for the complete description of the NixOS test framework.