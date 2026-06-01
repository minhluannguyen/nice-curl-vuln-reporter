#!/usr/bin/env python3
"""
A reproducible security report generator for cURL vulnerabilities, built with Nix.
Interactive tool to create new report cases, run tests, and manage VMs.
"""

import os
import sys
import subprocess
import json
import re
from pathlib import Path
from typing import Optional, List, Tuple
import urllib.request
import time
import yaml
import pexpect
import questionary

from jinja2 import Environment, FileSystemLoader, select_autoescape
from ruamel.yaml import YAML

# ANSI color codes
RED = '\033[0;31m'
GREEN = '\033[0;32m'
YELLOW = '\033[1;33m'
BLUE = '\033[0;34m'
NC = '\033[0m'  # No Color

# Directories
USER_DIR = Path.cwd()
REPORT_DIR = USER_DIR / "reports"

LIBRARY_DIR = Path(__file__).parent
TEMPLATE_DIR = LIBRARY_DIR / "template"

def info(msg: str):
    """Print info message"""
    print(f"{BLUE}ℹ️{NC} {msg}")


def success(msg: str):
    """Print success message"""
    print(f"{GREEN}✅{NC} {msg}")


def error(msg: str):
    """Print error message and exit"""
    print(f"{RED}❌{NC} {msg}", file=sys.stderr)
    sys.exit(1)


def warning(msg: str):
    """Print warning message"""
    print(f"{YELLOW}⚠️{NC} {msg}")


def prompt(question: str, default: str = "") -> str:
    """Prompt user for input with optional default"""
    if default:
        user_input = input(f"{BLUE}{question}{NC} [{default}]: ").strip()
        return user_input if user_input else default
    else:
        user_input = input(f"{BLUE}{question}{NC}: ").strip()
        if not user_input:
            error("Input cannot be empty")
        return user_input


def select_menu(prompt_text: str, options: List[str], default: Optional[int] = None) -> str:
    """Display menu and get user selection"""
    print()
    for i, option in enumerate(options, 1):
        print(f"{i}) {option}")
    
    while True:
        try:
            default_str = f'[{default}]' if default is not None else ''
            choice = input(f"{BLUE}{prompt_text}{NC}{default_str} ").strip()
            if not choice and default is not None:
                return options[default - 1]
            idx = int(choice) - 1
            if 0 <= idx < len(options):
                return options[idx]
            print("Invalid choice, please try again.")
        except ValueError:
            print("Invalid choice, please try again.")

def compute_nixpkgs_hash(commit: str) -> str:
    """Compute nixpkgs tarball sha256 hash for a given commit"""
    url = f"https://github.com/NixOS/nixpkgs/archive/{commit}.tar.gz"
    
    try:
        result = subprocess.run(
            ["nix-prefetch-url", url, "--unpack"],
            capture_output=True,
            text=True,
            timeout=30
        )
        if result.returncode == 0:
            # The output is just the hash on the last line
            hash_value = result.stdout.strip().split('\n')[-1].strip()
            if hash_value:
                return hash_value
    except (subprocess.TimeoutExpired, FileNotFoundError):
        pass
    
    warning(f"Could not compute hash for {url}")
    return ""

def fetch_commit_lazamar(curl_version: str) -> str:
    """Fetch nixpkgs commit from Lazamar nix-versions"""
    info(f"Trying Lazamar nix-versions for curl {curl_version}...")
    
    try:
        url = "https://lazamar.co.uk/nix-versions/?channel=nixpkgs-unstable&package=curl"
        with urllib.request.urlopen(url, timeout=5) as response:
            html_content = response.read().decode('utf-8')
            
            # Extract commit hash from HTML table
            pattern = f'<td>curl</td><td>{re.escape(curl_version)}</td><td><a[^>]*>([a-f0-9]{{40}})</a>'
            match = re.search(pattern, html_content)
            
            if match:
                commit = match.group(1)
                success(f"Found via Lazamar: {commit[:8]}...")
                return commit
    except Exception:
        pass
    
    warning(f"Lazamar did not have an entry for curl {curl_version}")
    return ""


def fetch_commit_latest() -> str:
    """Fetch latest nixpkgs commit from GitHub"""
    info("Fetching latest nixpkgs commit...")
    
    try:
        url = "https://api.github.com/repos/NixOS/nixpkgs/commits?per_page=1&sha=master"
        with urllib.request.urlopen(url, timeout=3) as response:
            data = json.loads(response.read().decode('utf-8'))
            if data and 'sha' in data[0]:
                commit = data[0]['sha']
                success(f"Found latest commit: {commit[:8]}...")
                return commit
    except Exception:
        pass
    
    warning("Could not fetch latest nixpkgs commit")
    return ""

def fetch_commit_from_csv(curl_version: str) -> str:
    """Fetch nixpkgs commit from CSV database"""
    info(f"Trying CSV database for curl {curl_version}...")
    
    csv_path = LIBRARY_DIR / "curl_nixpkgs_versions.csv"
    try:
        if not csv_path.exists():
            warning(f"CSV database not found at {csv_path}")
            return ""
        
        with open(csv_path, 'r') as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith('curl_version'):
                    continue  # Skip empty lines and header
                parts = [p.strip() for p in line.split(',')]
                if len(parts) >= 3 and parts[0] == curl_version and parts[2]:
                    commit = parts[2]
                    success(f"Found via CSV: {commit[:8]}...")
                    return commit
    except Exception as e:
        warning(f"Error reading CSV database: {e}")
        return ""
    
    warning(f"Nixpkgs did not have an entry for curl {curl_version}")
    return ""


def fetch_commit_for_version(curl_version: str) -> str:
    """Fetch nixpkgs commit for a given curl version"""
    info(f"Resolving curl {curl_version} to nixpkgs commit...")
    
    if curl_version == "latest":
        latest = fetch_commit_latest()
        if latest:
            return latest
        
    # Try CSV database
    csv_commit = fetch_commit_from_csv(curl_version)
    if csv_commit:
        return csv_commit
    
    # Try Lazamar (deprecated)
    # lazamar = fetch_commit_lazamar(curl_version)
    # if lazamar:
    #     return lazamar
    
    return ""

def check_and_suggest_curl_version() -> str:
    """Check if the provided curl version is valid and suggest alternatives if not"""

    # Check if the version is in the right format

    curl_version = questionary.text(
        "Enter vulnerable curl version (e.g., 8.4.0 or latest):",
        validate=lambda text: bool(re.match(r'^\d+\.\d+\.\d+$', text) or text == "latest") or "Please enter a valid version (e.g., 8.4.0 or latest)",
        qmark="❓",
    ).ask()
    
    # Suggest alternatives based on CSV database
    csv_path = LIBRARY_DIR / "curl_nixpkgs_versions.csv"
    version_list = []
    
    try:
        if csv_path.exists():
            with open(csv_path, 'r') as f:
                for line in f:
                    line = line.strip()
                    if not line or line.startswith('curl_version'):
                        continue  # Skip empty lines and header
                    parts = [p.strip() for p in line.split(',')]
                    if len(parts) >= 3 and parts[2]:  # Ensure there's a commit hash
                        if curl_version == parts[0]:
                            return curl_version  # Exact match found, return immediately
                        version_list.append(parts[0])
    except Exception as e:
        warning(f"Error reading CSV database: {e}")

    warning(f"Version {curl_version} not found in Nixpkgs. Suggesting alternatives...")
    
    suggestions = []
    if version_list:
        id = version_list.index(curl_version) + 1 if curl_version in version_list else 3
        for j in range(3):
            if id + j < len(version_list):
                suggestions.append(version_list[id + j])
            if id - j - 2 >= 0:
                suggestions.append(version_list[id - j - 2])
        sorted_suggestions = sorted(set(suggestions), key=lambda v: list(map(int, v.split('.'))))
        choice = questionary.select(
            message="Here are some additional curl versions available in Nixpkgs:",
            choices=sorted_suggestions,
            pointer="→",
            qmark="❓",
        ).ask()
    
    return choice if choice else curl_version

def create_security_report():
    """Create a new security report"""
    info("Creating new security report...")
    print()
    
    title = prompt("Enter short title", "curl-vulnerability")
    vulnerable_version = check_and_suggest_curl_version()
    
    strategy = select_menu("Curl build strategy?", ["Fetch from nixpkgs", "Build from source"], default=1)
    target = select_menu("Select curl package to target:", ["tool", "library"], default=1)
    attack_pattern = select_menu("Select attack pattern:", ["remote", "local", "other"], default=1)
    
    vuln_commit = ""
    vuln_hash = ""
    
    if strategy == "Fetch from nixpkgs":
        vuln_commit = fetch_commit_for_version(vulnerable_version)
        if vuln_commit:
            info(f"Computing sha256 hash for commit {vuln_commit}...")
            hash_raw = compute_nixpkgs_hash(vuln_commit)
            vuln_hash = "sha256:" + hash_raw if hash_raw else ""
            if vuln_hash:
                success(f"Computed sha256 hash: {vuln_hash[:16]}...")
    else:
        vuln_commit = "<NIXPKGS_COMMIT_HASH>"
        vuln_hash = ""
    
    if attack_pattern == "remote":
        is_attacker_server = select_menu("Is an attacker server needed for this vulnerability?", ["Yes", "No"], default=1) == "Yes"
    else:
        is_attacker_server = False

    attacker_server_language = None
    if is_attacker_server:
        attacker_server_language = select_menu("Select supported attacker server language:", ["C", "Python", "Bash"], default=1)
    
    is_custom_vms = select_menu("Are custom VMs needed for this report?", ["Yes", "No"], default=2) == "Yes"
    
    # Create case directory
    case_name = title
    case_dir = REPORT_DIR / case_name
    
    if case_dir.exists():
        error(f"Case directory already exists: {case_dir}")
    
    info("Creating directory structure...")
    (case_dir / "vm-configs").mkdir(parents=True)
    (case_dir / "exploit").mkdir(exist_ok=True)
    
    # Create report.yaml from template using Jinja2
    info("Generating report.yaml from template...")
    
    env = Environment(loader=FileSystemLoader(str(TEMPLATE_DIR)), autoescape=select_autoescape())
    template = env.get_template("report.yaml")
    
    content = template.render(
        short_title=title,
        curl_strategy="nixpkgs" if strategy == "Fetch from nixpkgs" else "source",
        curl_target=target,
        curl_version=vulnerable_version,
        curl_nixpkgs_commit_hash=vuln_commit,
        curl_nixpkgs_commit_sha256=vuln_hash,
        vm_attack_pattern=attack_pattern,
        is_attacker_server=is_attacker_server,
        attacker_server_language=attacker_server_language,
        custom_vms=is_custom_vms
    )
    
    # Write report.yaml
    report_yaml = case_dir / "report.yaml"
    report_yaml.write_text(content)
    
    # Copy template files
    info("Copying template files...")
    
    for template_file in ["flake.nix"]:
        src = TEMPLATE_DIR / template_file
        if src.exists():
            (case_dir / template_file).write_text(src.read_text())
    
    success(f"Report case created: {case_dir}")
    print()
    show_main_menu()

def calculate_sha256_src(source_url: str) -> str:
    try:
        result = subprocess.run(
            ["nix-prefetch-url", source_url],
            capture_output=True,
            text=True,
            timeout=60
        )
        if result.returncode == 0:
            hash_raw = result.stdout.strip().split('\n')[-1].strip()
            success(f"Computed hash: {hash_raw[:16]}...")
            
            # Convert hash from nix format to SRI format
            result = subprocess.run(
                ["nix", "hash", "convert", "--hash-algo", "sha256", "--to", "sri", hash_raw],
                capture_output=True,
                text=True
            )
            if result.returncode == 0:
                vuln_hash = result.stdout.strip()
                success(f"Converted hash to SRI: {vuln_hash}")
                
                return vuln_hash
            else:
                error(f"Failed to convert hash: {result.stderr}")
        else:
            error(f"Failed to compute hash: {result.stderr}")
    except FileNotFoundError:
        error("nix-prefetch-url or nix command not found")

    return ""

def update_single_hash(case_dir: Path, update_target: str):
    """Update hashes for a single case"""
    report_yaml = case_dir / "report.yaml"
    
    # Check if report.yaml exists
    if not report_yaml.exists():
        error(f"report.yaml not found in {case_dir}")
    
    info(f"Computing tarball hashes for: {case_dir.name}")
    print()
    
    # Parse YAML file using ruamel.yaml to preserve formatting
    yml = YAML()
    yml.preserve_quotes = True
    yml.default_flow_style = False
    
    with open(report_yaml, 'r') as f:
        data = yml.load(f)
    
    if not data or 'curl' not in data:
        error("Could not parse curl configuration from report.yaml")
    
    curl_config = data['curl']
    strategy = curl_config.get('strategy')
    
    if not strategy:
        error("Could not extract strategy from report.yaml")
    
    package = curl_config.get('package', {})
    vulnerable_version = package.get('version')
    
    if not vulnerable_version:
        error("Could not extract vulnerable version from report.yaml")
    
    if "Version" in update_target:
        info(f"Vulnerable version: {vulnerable_version}")
        
    if strategy == "nixpkgs":

        if "Version" in update_target:
            # Fetch commit hash for nixpkgs strategy
            vuln_commit = fetch_commit_for_version(vulnerable_version)
            if not vuln_commit:
                warning(f"Could not fetch commit hash for version {vulnerable_version}, please change to a different version")
                return
        elif "Commit hash" in update_target:
            vuln_commit = package.get('commit')
            if not vuln_commit:
                error("Could not extract existing commit hash from report.yaml")
        
        info("Computing vulnerable version hash...")
        hash_raw = compute_nixpkgs_hash(vuln_commit)
        vuln_hash = "sha256:" + hash_raw if hash_raw else ""
        success(f"Vulnerable hash: {vuln_hash}")
        
        # Update data dict with new values
        data['curl']['package']['commit'] = vuln_commit
        data['curl']['package']['sha256'] = vuln_hash
        
    elif strategy == "source":
        # For source strategy, compute hash and convert to SRI format
        source_url = package.get('url')
        if not source_url:
            error("Could not extract source URL from report.yaml")
        
        info(f"Computing source hash for {source_url}...")
        
        # Fetch the source and compute hash
        sha256_hash = calculate_sha256_src(source_url)
        data['curl']['package']['hash'] = sha256_hash
    
    info("Updating report.yaml with new hashes...")
    
    # Write back the modified YAML while preserving formatting
    with open(report_yaml, 'w') as f:
        yml.dump(data, f)
    
    success("Hashes saved to report.yaml")
    print()


def update_hashes():
    """Update hashes for existing cases"""
    info("Updating hashes for existing cases...")
    print()

    update_target = select_menu("Update from?", [
        "Version (update commit hash and sha256 from version)",
        "Commit hash (update sha256 from commit hash)",
    ])
    
    cases = sorted([d.name for d in REPORT_DIR.iterdir() if d.is_dir()])
    
    if not cases:
        error("No report cases found")
    
    cases.append("Cancel")
    selected = select_menu("Select security report:", cases)
    
    if selected == "Cancel":
        show_main_menu()
        return
    
    case_dir = REPORT_DIR / selected
    update_single_hash(case_dir, update_target)
    show_main_menu()

def update_flake_case(case_dir: Path):
    """Update nix flake for a single case"""
    info(f"Updating nix flake for: {case_dir.name}")
    print()
    
    try:
        result = subprocess.run(
            ["nix", "flake", "update"],
            cwd=case_dir,
            capture_output=True,
            text=True
        )
        
        if result.returncode == 0:
            success(f"Flake updated successfully: {case_dir.name}")
        else:
            warning(f"Failed to update flake: {case_dir.name}")
            print(result.stderr[-500:] if result.stderr else result.stdout[-500:])
    except Exception as e:
        error(f"Error updating flake: {e}")
    

def update_all_flakes():
    """Update nix flakes for all cases"""
    info("Updating nix flakes for all cases...")
    print()
    
    cases = sorted([d for d in REPORT_DIR.iterdir() if d.is_dir()])
    
    for case_dir in cases:
        update_flake_case(case_dir)
    
    print("\nPress Enter to return to menu...")
    input()

def update_flakes():
    """Update nix flakes for existing cases"""
    info("Updating nix flakes for existing cases...")
    print()
    
    cases = sorted([d.name for d in REPORT_DIR.iterdir() if d.is_dir()])
    
    if not cases:
        error("No report cases found")
    
    cases.extend(["All cases", "Cancel"])
    selected = select_menu("Select security report:", cases)
    
    if selected == "Cancel":
        show_main_menu()
        return
    
    if selected == "All cases":
        update_all_flakes()
    else:
        case_dir = REPORT_DIR / selected
        update_flake_case(case_dir)
    show_main_menu()

def run_single_test(case_dir: Path):
    """Run test for a single case"""
    case_name = case_dir.name
    info(f"Testing: {case_name}")
    print()
    
    try:
        result = subprocess.run(
            ["nix", "run", "--refresh", ".#testVulnerableTrue.driver"],
            cwd=case_dir,
            # capture_output=True,
            text=True
        )
        
        if result.returncode == 0:
            success(f"Test passed: {case_name}")
        else:
            warning(f"Test failed: {case_name}")
            print(result.stderr[-500:] if result.stderr else result.stdout[-500:])
    except Exception as e:
        error(f"Error running test: {e}")
    
    print("\nPress Enter to return to menu...")
    input()

def run_all_tests():
    """Run tests for all cases"""
    info("Running all tests...")
    print()
    
    passed = 0
    failed = 0
    
    cases = sorted([d for d in REPORT_DIR.iterdir() if d.is_dir() and (d / "report.yaml").exists()])
    
    for case_dir in cases:
        case_name = case_dir.name
        info(f"Testing: {case_name}")
        
        try:
            result = subprocess.run(
                ["nix", "run", "--refresh", ".#testVulnerableTrue.driver"],
                cwd=case_dir,
                capture_output=True,
                text=True
            )
            
            if result.returncode == 0:
                success(f"{case_name} passed")
                passed += 1
            else:
                warning(f"{case_name} failed")
                failed += 1
        except Exception as e:
            warning(f"Error running {case_name}: {e}")
            failed += 1
    
    print()
    print(f"{BLUE}═════════════════════════════════════════{NC}")
    print(f"{GREEN}Passed: {passed}{NC}")
    print(f"{RED}Failed: {failed}{NC}")
    print(f"{BLUE}═════════════════════════════════════════{NC}")

    print("\nPress Enter to return to menu...")
    input()

def run_tests():
    """Run tests menu"""
    info("Run report case tests...")
    print()
    
    cases = sorted([d.name for d in REPORT_DIR.iterdir() if d.is_dir() and (d / "report.yaml").exists()])
    
    if not cases:
        error("No report cases with report.yaml found")
    
    cases.extend(["All cases", "Cancel"])
    selected = select_menu("Select report case to test:", cases)
    
    if selected == "Cancel":
        show_main_menu()
        return
    
    if selected == "All cases":
        run_all_tests()
    else:
        case_dir = REPORT_DIR / selected
        run_single_test(case_dir)
    
    show_main_menu()

ANSI_RE = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]")

def strip_ansi(s: str) -> str:
    s = ANSI_RE.sub("", s)
    s = s.replace("\r\n", "\n").replace("\r", "\n")
    return s

def read_until_clean(child, needle: str, timeout: float = 120.0) -> str:
    deadline = time.time() + timeout
    raw_parts = []
    clean_buf = ""

    while time.time() < deadline:
        try:
            chunk = child.read_nonblocking(size=4096, timeout=1)
        except pexpect.TIMEOUT:
            continue

        raw_parts.append(chunk)
        clean_buf += strip_ansi(chunk)

        if needle in clean_buf:
            return clean_buf

    raise TimeoutError(f"Did not see cleaned text: {needle!r}")

def start_scenario():
    """Start scenario for a single case"""
    info("Starting scenario for a report case...")
    print()
    
    cases = sorted([d.name for d in REPORT_DIR.iterdir() if d.is_dir() and (d / "report.yaml").exists()])
    
    if not cases:
        error("No valid reports found")
    
    cases.append("Cancel")
    selected = select_menu("Select report to start scenario:", cases)
    
    if selected == "Cancel":
        show_main_menu()
        return
    
    case_dir = REPORT_DIR / selected
    
    try:
        subprocess.run(["bash", LIBRARY_DIR / "cleanup-script.sh"], capture_output=True)
    except Exception:
        pass
  
    # Extract VM names from flake
    info("Extracting VM names from flake...")
    try:
        subprocess.run(["git", "add", case_dir], cwd=USER_DIR, capture_output=True)

        child = pexpect.spawn(
            "nix run .#startScenario.driverInteractive",
            cwd=str(case_dir),
            encoding="utf-8",
            echo=False
        )

        # Log output to our terminal
        child.logfile_read = sys.stdout

        clean_text = read_until_clean(
            child,
            "additionally exposed symbols:",
            timeout=120,
        )

        ssh_commands = dict(re.findall(
            r"^\s*([A-Za-z0-9._-]+):\s+(ssh\b[^\r\n]+)$",
            clean_text,
            re.MULTILINE,
        ))

        child.sendline("test_script()")

        post_text = read_until_clean(
            child,
            "INTERACTIVE MODE SETUP COMPLETE. READY FOR INTERACTIVE TESTING.",
            timeout=120,
        )

        if len(ssh_commands) == 0:
            raise RuntimeError("Did not find any SSH commands in the output. Maybe there is no VM available?")
        
        info(f"{GREEN}To access the machines, use the following SSH commands:{NC}")
        for name, cmd in ssh_commands.items():
            print(f"  - {name}: {cmd}")

        info(f"{RED}To exit the scenario, press Ctrl+D in this terminal and choose 'Yes' to kill the VMs.{NC}")

        terminator_cmds = []
        for name, cmd in ssh_commands.items():
            terminator_cmds.append(f'terminator -T {name} -e "{cmd}"')

        full_cmd = " & ".join(terminator_cmds)

        time.sleep(2)  # Give some time for the child process to set up before launching terminator
        
        subprocess.Popen(
            ["bash", "-c", full_cmd],
            cwd=case_dir,
        )

        child.logfile = None
        child.logfile_read = None
        child.logfile_send = None
        child.interact()


    except Exception as e:
        error(f"Could not start scenario: {e}")
    
    show_main_menu()


def manage_vms():
    """Manage VMs menu"""
    info("Manage VMs for report cases...")
    print()
    
    cases = sorted([d.name for d in REPORT_DIR.iterdir() if d.is_dir() and (d / "report.yaml").exists()])
    
    if not cases:
        error("No valid reports found")
    
    cases.append("Cancel")
    selected = select_menu("Select report to view VMs:", cases)
    
    if selected == "Cancel":
        show_main_menu()
        return
    
    case_dir = REPORT_DIR / selected
    
    try:
        subprocess.run(["bash", LIBRARY_DIR / "cleanup-script.sh"], capture_output=True)
    except Exception:
        pass
  
    # Extract VM names from flake
    info("Extracting VM names from flake...")
    try:
        subprocess.run(["git", "add", case_dir], cwd=USER_DIR, capture_output=True)
        result = subprocess.run(
            ["nix", "flake", "show", "--json", "--allow-import-from-derivation"],
            cwd=case_dir,
            capture_output=True,
            text=True,
            timeout=10
        )
        
        if result.returncode == 0:
            data = json.loads(result.stdout)
            vm_list = []
            
            # Extract top-level vm keys (e.g., vmAttacker, vmClient)
            for key in data.keys():
                if key.startswith('vm') and key != 'vmCustom':
                    vm_list.append(key)
        
            # Extract vmCustom children using nix eval
            try:
                result = subprocess.run(
                    ["nix", "eval", ".#vmCustom", "--json"],
                    cwd=case_dir,
                    capture_output=True,
                    text=True,
                    timeout=10
                )
                if result.returncode == 0 and result.stdout.strip():
                    custom_vms = json.loads(result.stdout)
                    if isinstance(custom_vms, dict):
                        for child_name in custom_vms.keys():
                            vm_list.append(f"vmCustom.{child_name}")
            except Exception:
                pass
            
            if vm_list:
                vm_list.append("Cancel")
                choice = select_menu("Select VM to start:", vm_list)
                
                if choice != "Cancel":
                    info(f"Starting VM: {choice}")
                    subprocess.run(["nix", "run", f".#{choice}"], cwd=case_dir)
            else:
                warning("No VMs found in this case. Please check your flake.nix configuration.")
    except Exception as e:
        warning(f"Could not list VMs: {e}")
    
    show_main_menu()


def show_main_menu():
    """Display main menu"""
    print()
    print(f"{BLUE}╔═════════════════════════════════════════════════════════╗{NC}")
    print(f"{BLUE}║            A NICE cURL vulnerability reporter           ║{NC}")
    print(f"{BLUE}╚═════════════════════════════════════════════════════════╝{NC}")
    print()
    
    choice = select_menu(
        "What would you like to do?",
        [
            "Create new security report",
            "Update hashes for existing report",
            "Update nix flakes for existing report",
            "Start interactive scenario",
            "Run tests",
            "Exit"
        ]
    )
    
    if choice == "Create new security report":
        create_security_report()
    elif choice == "Update hashes for existing report":
        update_hashes()
    elif choice == "Update nix flakes for existing report":
        update_flakes()
    elif choice == "Start interactive scenario":
        start_scenario()
    elif choice == "Run tests":
        run_tests()
    elif choice == "Exit":
        sys.exit(0)


def main():
    """Main entry point"""
    if not REPORT_DIR.exists():
        warning(f"Report directory not found, creating: {REPORT_DIR}")
        REPORT_DIR.mkdir(parents=True)
    
    show_main_menu()


if __name__ == "__main__":
    main()

