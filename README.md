# Template: curl CVE Case

This folder is a starter template for CVE reproductions using the shared library at `src`.

## Files

- `cve.yaml`: preferred case descriptor format
- `cve.toml`: compatibility descriptor format
- `flake.nix`: exposes build/test outputs (`vmClient`, `vmAttacker`, `testVulnerableTrue`, ...)
- `vm-configs/*.nix`: per-node NixOS config overrides
- `test-scripts/test-script.py`: NixOS test script
- `exploit/`: exploit artifacts/scripts

## Descriptor format

The library currently prefers `cve.yaml` and falls back to `cve.toml`.

Required top-level fields:

- `cve_id`
- `title`
- `curl`
- `vm`
- `test_script_path`
- `assertions` (list)

Recommended:

- `meta`

## `curl` block

```yaml
curl:
  nixpkgs_strategy: tarball  # or custom
  vulnerable:
    nixpkgs_url: https://github.com/NixOS/nixpkgs/archive/<commit>.tar.gz
    nixpkgs_sha256: sha256:<hash>
    curl_version: X.Y.Z
  patched:
    nixpkgs_url: https://github.com/NixOS/nixpkgs/archive/<commit>.tar.gz
    nixpkgs_sha256: sha256:<hash>
    curl_version: A.B.C
```

If `nixpkgs_strategy: custom`, use `curl.custom_src`.

## `vm` block

### Common

- `vm.pattern`: use `remote` to include attacker node
- `vm.custom_vm`: set `true` to enable `vm.custom_vms`

### Client (outbound forwarding)

Use these keys:

- `outbound_guest_ports`
- `outbound_host_ports`
- optional `outbound_guest_address` (default: `10.0.2.10`)

Both port fields accept either:

- a single integer (e.g. `8080`)
- a list of integers (e.g. `[8080, 8081]`)

### Attacker (inbound forwarding)

Use these keys:

- `inbound_guest_ports`
- `inbound_host_ports`

Both support single integer or list.

### Custom VMs (supports inbound + outbound)

Each node under `vm.custom_vms.<name>` may define:

- `config_path`
- inbound: `inbound_guest_ports` / `inbound_host_ports`
- outbound: `outbound_guest_ports` / `outbound_host_ports`

Legacy fallback is also supported for inbound mapping when inbound keys are absent:

- `guest_ports` / `host_ports`
- `guest_port` / `host_port`

## Assertions

Use a list in `assertions`:

```yaml
assertions:
  - name: oom
    params:
      machine: client
      command: curl attacker:8080
      maximum_memory_bytes: 536870912
```

Supported names are defined by `src/assertion/make-assertion.nix`.

## Quick usage

From a case directory (e.g. a copied template):

```bash
nix build .#vmClient
nix build .#testVulnerableTrue.driver
```

## Notes

- Keep port list lengths aligned (guest and host) for each direction.
- Prefer `cve.yaml` for new cases.
- Use `vm-configs/*.nix` for service/runtime customization instead of bloating descriptor fields.
