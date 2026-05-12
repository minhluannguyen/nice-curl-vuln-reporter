# A NICE cURL Vulnerability reporter

This library provides a structured and reproducible way to report cURL vulnerabilities using the NICE framework.
Each vulnerability case is defined by a user-friendly descriptor `report.yaml` that specifies the vulnerable cURL package, VM configuration, test script that simulates the attack with assertions to validate the existence of the vulnerability. 

### Prerequisites

- You need Nix in order to use this library, you can install it by following the instructions on the official Nix website: https://nixos.org/download.html. Or, run the following command in your terminal (for Linux users):

```bash
sh <(curl --proto '=https' --tlsv1.2 -L https://nixos.org/nix/install) --daemon
```

- The library uses Flakes - a new feature in Nix that provides a more structured and reproducible way to manage Nix projects. Enable flakes by adding the following lines to `/etc/nix/nix.conf`:

```
experimental-features = nix-command flakes
```

- KVM acceleration is also required to run the VMs. Make sure your system supports KVM and that it is properly configured.

### Usage

Go to [How-to Guides](./docs/how-to-guides.md) for instructions on how to create new curl vulnerability reports with NICE.

For detailed documentation on the structure of the YAML report file and the available fields, see [YAML Report Structure](./docs/documentation.md).

## Structure

Main project files and directories:
- `nice-report.py`: CLI helper script to navigate through the library and orchestrate VM builds and test runs.
- `cleanup-script.sh`: helper script to clean up temporary files.
- `src/`: library source code.
- `reports/`: directory containing vulnerability reports, with example cases from CVEs.
- `templates/`: template files for new vulnerability reports.

Each case directory:
- `report.yaml`: vulnerability descriptor
- `flake.nix`: Nix flake for the case, exposing VM and test targets
- `vm-configs/*.nix`: Extendable VM configurations
- `test-script.py`: Extendable test script
- `exploit/`: exploit artifacts/scripts

## The CLI report helper tool
This tool provides a command-line interface to interact with the vulnerability reports.

### 1. Run as a Nix application:
You can run the helper script using Nix run. First, clone the repository if you want to run the example, then run the following command from the project root:
```bash
nix run
```

If you already have available reports to work with, within the same directory containing the `reports/` folder, run:
```bash
nix run 'github:minhluannguyen/nice-curl-vuln-reporter'
```

*Note*: Add the `--refresh` flag to the `nix run` command if you want to make sure you are running the latest version on the `master` branch.

### 2. Functionality:

```bash
╔═════════════════════════════════════════════════════════╗
║            A NICE cURL vulnerability reporter           ║
╚═════════════════════════════════════════════════════════╝


1) Create new security report
2) Update hashes for existing report
3) Update nix flakes for existing report
4) Start interactive scenario
5) Run tests
6) Exit
What would you like to do? 
```

1) Create new security report: Creates a new vulnerability report from a template after asking a series of questions.
2) Update hashes for existing report: Updates the nix hashes in the `report.yaml` file for a given case. If the case uses the `nixpkgs` strategy, it will update the `commit` and `sha256` fields. If the case uses the `source` strategy, it will update the `hash` field.
3) Update nix flakes for existing report: Updates the nix flakes in the `flake.nix` file for security reports. This changes the `.lock` file to point to the latest version of the library. 
4) Start interactive scenario: automatically builds and sets up all the necessary VMs for a given vulnerability report and starts an interactive session where the user can manually run commands on the VMs.
5) Run tests: Provides options for running the tests for a given case or all cases in the `reports/` directory.
6) Exit: Exits the script.

## Direct use (without the helper script)

This can be helpful for debugging or if you want more control over the VM management and test execution.
From a case directory:

```bash
# Show all possible targets
nix flake show

# Start the VMs
nix run .#vmClient

# Run the test script
nix run .#testVulnerableTrue.driver
# For interactive mode
nix run .#testVulnerableTrue.driverInteractive
```

## Example reports

All example reports are located in the `reports/` directory. Each case is organized in its own subdirectory, named after the CVE it represents. A summary of the reproduced curl vulnerability is provided [here](./reports/README.md).