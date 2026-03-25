#!/usr/bin/env bash
# A reproducible security report generator for cURL vulnerabilities, built with Nix
# Interactive tool to create new report cases, run tests, and manage VMs

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPORT_DIR="$SCRIPT_DIR/reports"
TEMPLATE_DIR="$SCRIPT_DIR/template"

# Colors for output
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
NC=$'\033[0m' # No Color

# Print colored messages
info() { echo -e "${BLUE}ℹ️${NC} $*"; }
success() { echo -e "${GREEN}✅${NC} $*"; }
error() { echo -e "${RED}❌${NC} $*"; exit 1; }
warning() { echo -e "${YELLOW}⚠️${NC} $*"; }

# Prompt user for input with default value
prompt() {
    local prompt="$1"
    local default="$2"
    local input
    
    if [[ -n "$default" ]]; then
        read -p "${BLUE}${prompt}${NC} [${default}]: " input
        echo "${input:-$default}"
    else
        read -p "${BLUE}${prompt}${NC}: " input
        if [[ -z "$input" ]]; then
            error "Input cannot be empty"
        fi
        echo "$input"
    fi
}

# Menu selection
select_menu() {
    local prompt="$1"
    shift
    local options=("$@")
    PS3="$(echo -e ${BLUE})${prompt}${NC} "
    select option in "${options[@]}"; do
        if [[ -n "$option" ]]; then
            echo "$option"
            break
        fi
    done
}

# ============================================================================
# Main Menu
# ============================================================================

show_main_menu() {
    echo ""
    echo -e "${BLUE}╔═════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║            A NICE cURL vulnerability reporter           ║${NC}"
    echo -e "${BLUE}╚═════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    local choice
    choice=$(select_menu "What would you like to do?" \
        "Create new security report" \
        "Update hashes for existing report" \
        "Manage VMs" \
        "Run tests" \
        "Exit")
    
    case "$choice" in
        "Create new security report") create_security_report ;;
        "Update hashes for existing report") update_hashes ;;
        "Manage VMs") manage_vms ;;
        "Run tests") run_tests ;;
        "Exit") exit 0 ;;
        *) error "Invalid choice" ;;
    esac
}

# ============================================================================
# Helper Functions
# ============================================================================

# Compute nixpkgs tarball sha256 hash for a given commit
compute_nixpkgs_hash() {
    local commit="$1"
    local ref="github:NixOS/nixpkgs/${commit}"
    
    if ! command -v nix &> /dev/null; then
        warning "nix command not found, skipping hash computation" >&2
        echo ""
        return 0
    fi
    
    local hash
    hash=$(timeout 30 nix flake prefetch "$ref" --json 2>/dev/null | grep -o '"hash":"[^"]*"' | cut -d'"' -f4)
    
    if [[ -n "$hash" ]]; then
        echo "$hash"
        return 0
    else
        warning "Could not compute hash for $ref" >&2
        echo ""
        return 0
    fi
}

fetch_commit_lazamar() {
    local curl_version="$1"
    
    info "Trying Lazamar nix-versions for curl $curl_version..." >&2
    local commit
    # Parse the HTML table to extract the revision for this specific version
    commit=$(curl -s --max-time 5 "https://lazamar.co.uk/nix-versions/?channel=nixpkgs-unstable&package=curl" 2>/dev/null \
        | sed -n "s/.*<td>curl<\/td><td>${curl_version}<\/td><td><a[^>]*>\([a-f0-9]\{40\}\)<\/a>.*/\1/p" \
        | head -1)
    
    if [[ -n "$commit" ]]; then
        success "Found via Lazamar: ${commit:0:8}..." >&2
        echo "$commit"
        return 0
    else
        warning "Lazamar did not have an entry for curl $curl_version" >&2
        echo ""
        return 0
    fi
}

fetch_commit_latest() {
    info "Fetching latest nixpkgs commit..." >&2
    local commit
    commit=$(curl -s --max-time 3 "https://api.github.com/repos/NixOS/nixpkgs/commits?per_page=1&sha=master" 2>/dev/null \
        | grep '"sha"' | head -1 | grep -o '[a-f0-9]\{40\}')
    
    if [[ -n "$commit" ]]; then
        success "Found latest commit: ${commit:0:8}..." >&2
        echo "$commit"
        return 0
    else
        warning "Could not fetch latest nixpkgs commit" >&2
        echo ""
        return 0
    fi
}

# Fetch nixpkgs commit hash for a given curl version
# Primary: Lazamar nix-versions (best historical version mapping)
# Fallback: GitHub API (for master branch), manual input
fetch_commit_for_version() {
    local curl_version="$1"
    
    info "Resolving curl $curl_version to nixpkgs commit..." >&2
    
    # Get latest nixpkgs master commit
    if [[ "$curl_version" == "latest" ]]; then
        local latest_commit
        latest_commit=$(fetch_commit_latest)
        if [[ -n "$latest_commit" ]]; then
            echo "$latest_commit"
            return 0
        fi
    fi

    # Lazamar
    local lazamar_commit
    lazamar_commit=$(fetch_commit_lazamar "$curl_version")
    if [[ -n "$lazamar_commit" ]]; then
        echo "$lazamar_commit"
        return 0
    fi
    
    # Last resort: ask user to provide commit manually
    # warning "Could not automatically resolve curl $curl_version" >&2
    # warning "You can:" >&2
    # warning "  1. Go to nixpkgs GitHub repo and search for the commit that updated curl to version $curl_version" >&2
    # warning "  2. Edit report.yaml and replace the commit hash manually" >&2
    
    # read -p "$(echo -e ${YELLOW})Enter nixpkgs commit hash manually (or press Enter to use 'master'):${NC} " manual_commit
    
    # if [[ -z "$manual_commit" ]]; then
    #     manual_commit="master"
    #     warning "Using 'master' branch reference" >&2
    # fi
    
    # echo "$manual_commit"
    # return 0
}

# ============================================================================
# Create New Security Report
# ============================================================================

create_security_report() {
    info "Creating new security report..."
    echo ""
    
    # Get report info
    local cve_id
    cve_id=$(prompt "Enter CVE ID" "CVE-YYYY-XXXXX")
    
    local title
    title=$(prompt "Enter short title" "curl-vulnerability")
    
    local vulnerable_version
    vulnerable_version=$(prompt "Enter vulnerable curl version" "latest")
    
    # Get strategy
    local strategy
    strategy=$(select_menu "Curl build strategy?" "Fetch from nixpkgs" "Build from source")

    # Get attack pattern
    local attack_pattern
    attack_pattern=$(select_menu "Select attack pattern:" \
        "remote" \
        "local" \
        "other")

    local target
    target=$(select_menu "Select curl package to target:" \
        "tool" \
        "library")
    
    local vuln_commit
    
    if [[ "$strategy" == "Fetch from nixpkgs" ]]; then
        # Fetch commit for vulnerable version
        vuln_commit=$(fetch_commit_for_version "$vulnerable_version")
        
        # Compute sha256 hash for the nixpkgs commit
        info "Computing sha256 hash for commit $vuln_commit..." >&2
        local vuln_hash
        vuln_hash=$(compute_nixpkgs_hash "$vuln_commit")
        if [[ -n "$vuln_hash" ]]; then
            success "Computed sha256 hash: ${vuln_hash:0:16}..." >&2
        fi
    else
        # For custom source strategy, placeholder values
        vuln_commit="<URL_AND_HASH_HERE>"
        vuln_hash=""
    fi
    
    # Create case directory
    local case_name

    if [[ "$cve_id" != "CVE-"* ]]; then
        case_name="$title"
    else
        case_name="${cve_id}-${title}"
    fi 
    
    local case_dir="$REPORT_DIR/$case_name"
    
    if [[ -d "$case_dir" ]]; then
        error "Case directory already exists: $case_dir"
    fi
    
    info "Creating directory structure..."
    mkdir -p "$case_dir"/{vm-configs,exploit,test-scripts}
    
    # Create report.yaml from template
    info "Generating report.yaml from template..."
    
    if [[ ! -f "$TEMPLATE_DIR/report.yaml" ]]; then
        error "Template report.yaml not found: $TEMPLATE_DIR/report.yaml"
    fi
    
    # Copy template and substitute values
    cp "$TEMPLATE_DIR/report.yaml" "$case_dir/report.yaml"
    
    # Read the template and do careful string replacements
    local content
    content=$(cat "$case_dir/report.yaml")
    
    # Use bash string replacement (handles special characters better than sed)
    content="${content//CVE-YYYY-XXXXX/$cve_id}"
    content="${content//<short-title>/$title}"
    content="${content//<VULNERABLE_COMMIT_HASH>/$vuln_commit}"
    content="${content//X.Y.Z/$vulnerable_version}"
    
    # Substitute sha256 hash if available (convert from sha256-<base64> to sha256:<base64>)
    if [[ -n "$vuln_hash" ]]; then
        # Replace "sha256-" with "sha256:" for consistency
        vuln_hash="${vuln_hash/sha256-/sha256:}"
        content="${content//<BASE64_HASH>/$vuln_hash}"
    fi

    content="${content//remote/$attack_pattern}"
    content="${content//tool/$target}"
    
    # Remove only indented comments (those with leading whitespace before #)
    # Keep top-level comments (no leading whitespace before #)
    content=$(echo "$content" | sed '/^[[:space:]]\+#/d')
    
    # Write back to file
    printf '%s\n' "$content" > "$case_dir/report.yaml"
    
    # Copy template files
    info "Copying template files..."
    cp "$TEMPLATE_DIR/flake.nix" "$case_dir/"
    cp "$TEMPLATE_DIR/test-scripts/test-script.py" "$case_dir/test-scripts/" 2>/dev/null || true
    cp "$TEMPLATE_DIR/vm-configs/client.nix" "$case_dir/vm-configs/" 2>/dev/null || true
    cp "$TEMPLATE_DIR/vm-configs/attacker.nix" "$case_dir/vm-configs/" 2>/dev/null || true
    
    success "Report case created: $case_dir"
    echo ""
    
    show_main_menu
}

# ============================================================================
# Update Hashes for Existing Cases
# ============================================================================

update_hashes() {
    info "Updating hashes for existing cases..."
    echo ""
    
    # List available cases
    local cases=()
    if [[ -d "$REPORT_DIR" ]]; then
        while IFS= read -r -d '' case_dir; do
            cases+=("$(basename "$case_dir")")
        done < <(find "$REPORT_DIR" -maxdepth 1 -type d ! -name "reports" -print0 | sort -z)
    fi
    
    if [[ ${#cases[@]} -eq 0 ]]; then
        error "No report cases found in $REPORT_DIR"
    fi
    
    cases+=("Cancel")
    
    local selected
    selected=$(select_menu "Select security report:" "${cases[@]}")
    
    if [[ "$selected" == "Cancel" ]]; then
        show_main_menu
        return
    fi
    
    local case_dir="$REPORT_DIR/$selected"
    update_single_hash "$case_dir"
    
    show_main_menu
}

compute_hash() {
    local commit="$1"
    local ref="github:NixOS/nixpkgs/${commit}"
    
    local hash
    hash=$(nix flake prefetch "$ref" --json 2>/dev/null | grep -o '"hash":"[^"]*"' | cut -d'"' -f4)
    
    if [[ -z "$hash" ]]; then
        error "Failed to compute hash for $ref"
    fi
    
    echo "$hash"
}

update_single_hash() {
    local case_dir="$1"
    local report_yaml="$case_dir/report.yaml"
    
    if [[ ! -f "$report_yaml" ]]; then
        error "report.yaml not found in $case_dir"
    fi
    
    info "Computing tarball hashes for: $(basename $case_dir)"
    echo ""

    # Extract vulnerable version from report.yaml (under curl.vulnerable.version)
    local vulnerable_version
    vulnerable_version=$(sed -n '/vulnerable:/,/^[^ ]/p' "$report_yaml" | grep "version:" | sed -E 's/.*version:[[:space:]]+([0-9.]+).*/\1/')
    
    if [[ -z "$vulnerable_version" ]]; then
        error "Could not extract vulnerable version from $report_yaml"
    fi
    
    info "Vulnerable version: $vulnerable_version"
    
    # Fetch commit hash
    local vuln_commit
    vuln_commit=$(fetch_commit_lazamar "$vulnerable_version")

    if [[ -z "$vuln_commit" ]]; then
        warning "Could not fetch commit hash for version $vulnerable_version, please change to a different version"
        return
    fi

    # Check if commit hash field exists 
    if grep -q "commit:" "$report_yaml"; then
        warning "Existing commit field found in $report_yaml, it will be updated"
    else
        warning "No commit field found in $report_yaml, it will be added"
        # Add placeholder commit field after the version line
        sed -i "/version:/a\    commit: <VULNERABLE_COMMIT_HASH>" "$report_yaml"
    fi

    # Check if sha256 hashes fields exist, if not, we will add them
    if grep -q "sha256:" "$report_yaml"; then
        warning "Existing sha256 fields found in $report_yaml, they will be updated"
    else
        warning "No sha256 fields found in $report_yaml, they will be added"
        # Add placeholder sha256 fields after the commit lines
        sed -i "/commit: $vuln_commit/a\    sha256: <BASE64_HASH>" "$report_yaml"
    fi
    
    info "Computing vulnerable version hash..."
    local vuln_hash
    vuln_hash=$(compute_hash "$vuln_commit")
    # Convert from sha256-<base64> to sha256:<base64>
    vuln_hash="${vuln_hash/sha256-/sha256:}"
    success "Vulnerable hash: $vuln_hash"
    
    # Update report.yaml using sed to replace whatever after "sha256:" with the new hash
    info "Updating report.yaml with hashes..."
    # Update commit hash (use | as delimiter)
    local escaped_commit
    escaped_commit=$(printf '%s\n' "$vuln_commit" | sed -e 's/[&]/\\&/g')
    sed -i "s|commit: .*|commit: ${escaped_commit}|" "$report_yaml"
    # Escape special characters in hash for use in sed replacement (use | as delimiter to avoid / conflicts)
    local escaped_hash
    escaped_hash=$(printf '%s\n' "$vuln_hash" | sed -e 's/[&]/\\&/g')
    sed -i "s|sha256: .*|sha256: ${escaped_hash}|" "$report_yaml"
    
    success "Hashes saved to report.yaml"
    echo ""
}

# ============================================================================
# Run Tests
# ============================================================================

run_tests() {
    info "Run report case tests..."
    echo ""
    
    # List available cases
    local cases=()
    if [[ -d "$REPORT_DIR" ]]; then
        while IFS= read -r -d '' case_dir; do
            if [[ -f "$case_dir/report.yaml" ]]; then
                cases+=("$(basename "$case_dir")")
            fi
        done < <(find "$REPORT_DIR" -maxdepth 1 -type d ! -name "reports" -print0 | sort -z)
    fi
    
    if [[ ${#cases[@]} -eq 0 ]]; then
        error "No report cases with report.yaml found"
    fi
    
    cases+=("All cases" "Cancel")
    
    local selected
    selected=$(select_menu "Select report case to test:" "${cases[@]}")
    
    if [[ "$selected" == "Cancel" ]]; then
        show_main_menu
        return
    fi
    
    if [[ "$selected" == "All cases" ]]; then
        run_all_tests
    else
        local case_dir="$REPORT_DIR/$selected"
        run_single_test "$case_dir"
    fi
    
    show_main_menu
}

run_single_test() {
    local case_dir="$1"
    local case_name=$(basename "$case_dir")
    
    info "Testing: $case_name"
    echo ""

    cd "$case_dir"
    
    run_test_target "$case_dir" "testVulnerableTrue"
    
    cd "$SCRIPT_DIR"
    echo ""
}

run_test_target() {
    local case_dir="$1"
    local target="$2"
    
    info "Running: nix run .#$target".driver
    echo ""
    
    if cd "$case_dir" && nix run ".#$target".driver 2>&1; then
        success "Test passed: $target"
    else
        error "Test failed: $target"
    fi

    read -p "Press Enter to continue..." < /dev/tty
}

run_all_tests() {
    info "Running all tests..."
    echo ""
    
    local passed=0
    local failed=0
    
    while IFS= read -r -d '' case_dir; do
        local case_name=$(basename "$case_dir")
        
        if [[ -f "$case_dir/report.yaml" ]]; then
            info "Testing: $case_name"
            
            if cd "$case_dir" && nix build ".#testVulnerableTrue" 2>&1 | tail -5; then
                success "$case_name passed"
                ((passed++))
            else
                warning "$case_name failed"
                ((failed++))
            fi
            
            cd "$SCRIPT_DIR"
        fi
    done < <(find "$REPORT_DIR" -maxdepth 1 -type d ! -name "reports" -print0 | sort -z)
    
    echo ""
    echo -e "${BLUE}═════════════════════════════════════════${NC}"
    echo -e "${GREEN}Passed: $passed${NC}"
    echo -e "${RED}Failed: $failed${NC}"
    echo -e "${BLUE}═════════════════════════════════════════${NC}"
}

# ============================================================================
# Manage VMs
# ============================================================================

manage_vms() {
    info "Manage VMs for report cases..."
    echo ""
    
    list_available_reports
    
    cd "$SCRIPT_DIR"
    show_main_menu
}

show_vm_actions() {
    local report_dir="$1"
    local action
    action=$(select_menu "Select VM action:" \
        "Start VM" \
        "Back to main menu")

    case "$action" in
        "Start VM")
            start_vm_interactive "$report_dir"
            ;;
        "Back to main menu")
            return
            ;;
        *) error "Invalid choice" ;;
    esac
}

list_available_reports() {
    info "Select report..."

    # List available cases
    local cases=()
    if [[ -d "$REPORT_DIR" ]]; then
        while IFS= read -r -d '' case_dir; do
            if [[ -f "$case_dir/report.yaml" ]]; then
                cases+=("$(basename "$case_dir")")
            fi
        done < <(find "$REPORT_DIR" -maxdepth 1 -type d ! -name "reports" -print0 | sort -z)
    fi

    if [[ ${#cases[@]} -eq 0 ]]; then
        error "No valid reports found in $REPORT_DIR"
    fi
    
    local selected
    selected=$(select_menu "Select report to view VMs:" "${cases[@]}" "Cancel")
    
    if [[ "$selected" == "Cancel" ]]; then
        return
    fi
    
    local case_dir="$REPORT_DIR/$selected"

    show_vm_actions "$case_dir"
}

start_vm_interactive() {
    local case_dir="$1"
    
    info "Fetching available VMs ..."
    warning "To exit the VM console, press Ctrl+A followed by X"
    
    bash $SCRIPT_DIR/cleanup-script.sh || true
    cd "$case_dir"

    # Extract VM names from flake outputs
    local vm_list=()
    if [[ -f "flake.nix" ]]; then
        # Extract top-level vm keys (e.g., vmAttacker, vmClient)
        # Use nix flake show --json for reliable parsing
        local flake_json
        flake_json=$(nix flake show --json 2>/dev/null || true)
        
        while IFS= read -r name; do
            if [[ "$name" =~ ^vm && "$name" != "vmCustom" ]]; then
                vm_list+=("$name")
            fi
        done < <(echo "$flake_json" | grep -o '"vm[^"]*"' | sed 's/"//g' | sort | uniq)
        
        # Extract vmCustom children using nix eval
        # vmCustom contains a set of VMs that can be customized
        if nix eval ".#vmCustom" --json 2>/dev/null | grep -q '{'; then
            while IFS= read -r child_name; do
                if [[ -n "$child_name" ]]; then
                    vm_list+=("vmCustom.$child_name")
                fi
            done < <(nix eval ".#vmCustom" --json 2>/dev/null | grep -o '"[^"]*":' | sed 's/"//g' | sed 's/:$//')
        fi
    fi
    
    if [[ ${#vm_list[@]} -eq 0 ]]; then
        warning "No VMs found in this case. Please check your flake.nix configuration."
        return
    fi
    
    vm_list+=("Cancel")
    
    local vm_choice
    vm_choice=$(select_menu "Select VM to start:" "${vm_list[@]}")
    
    if [[ "$vm_choice" == "Cancel" ]]; then
        return
    fi
    
    info "Starting VM: $vm_choice"
    nix run ".#$vm_choice"
}

# ============================================================================
# Main Entry Point
# ============================================================================

main() {
    if [[ ! -d "$REPORT_DIR" ]]; then
        error "reports directory not found: $REPORT_DIR"
    fi
    
    if [[ ! -d "$TEMPLATE_DIR" ]]; then
        error "Template directory not found: $TEMPLATE_DIR"
    fi

    git add . >/dev/null 2>&1 || true
    
    show_main_menu
}

# Run main if script is executed directly
main "$@"
