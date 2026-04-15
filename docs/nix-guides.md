# Nix Guides for Writing curl Vulnerability Reports

If you need a VMs with specific services or configurations to demonstrate the vulnerability, you can use NixOS configuration to extend the provided VM templates. This document provides some examples and guidelines on how to write NixOS configuration for the VMs in the vulnerability report.

## Getting Started

To create a new vulnerability report, you can run the `nice-report.py` script and select the "Create new security report" option. This will guide you through a series of questions to gather the necessary information for the report. The script will then generate a new directory under `reports/` with a template `report.yaml` file that you can edit to add the details of the vulnerability.

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

### Install software with Nixpkgs

Nixpkgs provides a wide range of packages that can be easily installed in the VMs. You can simply add the required packages to the `environment.systemPackages` option in the VM configuration file. For example, to install `vim`, `gdb` and `socat` on the client VM:

```nix
# client.nix
...
    environment.systemPackages = with pkgs; [
        vim
        gdb
        socat
    ];
...
```

The list of available packages can be found on the [Nix Packages Search](https://search.nixos.org/packages).
This can be useful for installing debugging tools or other software needed to demonstrate the vulnerability.

### Use built-in NixOS services and options

Apart from individual packages, NixOS also provides options to set up services that require more complex configurations and conditions. Examples include OpenSSH server, OpenSMTPD mail server, Apache web server, or system settings like adding a new user or opening firewall ports. An example NixOS configuration:

```nix
{ config, pkgs, ... }:
{
    # Use a specific kernel version to reproduce the vulnerability if needed
    boot.kernelPackages = pkgs.linuxPackages_5_10;

    # Set up a new user 'alice' with password authentication
    users.users.alice = {
        isNormalUser = true;
        password = "password";
    };


    # Set up OpenSSH server
    services.openssh.enable = true;

    # OpenSMTPD service
    services.opensmtpd = {
        enable = true;
        services.opensmtpd.serverConfiguration = ''
            listen on "0.0.0.0"

            action "local" mbox alias <aliases>
            action "relay" relay

            match from any for domain "example.org" action "local"
            match for local action "local"
            match from local for any action "relay"
        '';
    };
}
```

Detailed NixOS options can be found in the [NixOS options search](https://search.nixos.org/options).

Specific configuration and usage examples for well-known services can also be found in [NixOS Wiki](https://nixos.wiki/wiki/Main_Page).

### Systemd services for custom scripts

Maybe you want a custom script running to set up the environment (e.g., create dummy files, directories, run custom server, etc.), you can create a systemd service to run the script on boot or whenever needed. This is also provided as an option in the NixOS configuration:

```nix
...
    systemd.services = {
        setupEnvironment = {
        description = "Custom environment setup";
        wantedBy = [ "multi-user.target" ];
        after = [ "network.target" ];
        path = [ /path/to/your/script ];
        script = ''
            /path/to/your/script 2>&1
        '';
        };
    };
...
```

### Custom server setup

The current NICE framework supports wrapper scripts to start the server with provided parameters like source files, build configuration, etc. However, if the server setup requires more complex configurations or dependencies, it is recommended to set up the server directly using Nix expression. This is an example of setting up a malicious server with NixOS configuration:

```nix
{ pkgs, ... }:
let
    maliciousServerDerivation = pkgs.stdenv.mkDerivation {
        name = "malicious-server";
        version = "1.0";
        src = ../exploit/server;
        nativeBuildInputs = [ pkgs.gcc ];
        
        buildPhase = ''
            gcc -o exploit exploit.c
        '';

        installPhase = ''
            mkdir -p $out/bin
            cp exploit $out/bin/
        '';
    };

    startServerScript = pkgs.writeScriptBin "start-server" ''
        #!${pkgs.bash}/bin/bash
        ${maliciousServerDerivation}/bin/exploit 2>&1
    '';
in
{
    systemd.services = {
        maliciousServer = {
            description = "Malicious Server";
            wantedBy = [ "multi-user.target" ];
            path = [ startServerScript ];
            script = ''
                start-server
            '';
        };
    };
}
```

Here we create a custom derivation to build the malicious server from source code (written in C) and then create a wrapper script to start the server. Finally, we set up a systemd service to run the server on boot, similar technique shown in the previous section.

You can change the build configuration with different compiler flags or installation steps in the `buildPhase` and `installPhase` as needed.

More details on how to package and build software with Nix can be found in the [Nix Pills derivation](https://nixos.org/guides/nix-pills/20-basic-dependencies-and-hooks.html).

#### Run Python code in Nix expression

If your server is written in Python and requires some external Python packages, you can create a modified Python environment with the required packages and use it to run the server. Here is an example taken from CVE-2025-5399:

```nix
    modifiedPyPkgs = pkgs.python3.withPackages (python-pkgs: [
        python-pkgs.pwntools
    ]);

    serverFiles = pkgs.runCommand "server-files" { } ''
        mkdir -p $out
        cp -r ${./exploit/server} $out/exploit
    '';

    startServerScript = pkgs.writeScriptBin "start-server" ''
        #!${pkgs.bash}/bin/bash
        cd ${serverFiles}
        ${modifiedPyPkgs}/bin/python3 ${serverFiles}/exploit/exploit-server.py
    '';
```

As you can see, the `withPackages` function is used to create a modified Python package set that includes the required external packages (in this case, `pwntools`). To find the matching package name in Nixpkgs, you can search for the package on the [Nix Packages Search](https://search.nixos.org/packages) (usually the package name is the same as the Python package name).

### Complex networking setup

Most of the case, the vulnerabilities can be demonstrated with the available attacker patterns supported by the NICE framework. However, if you need a more complex networking setup (e.g. VM on different subnets, specific firewall rules, etc.), for more convincing demonstration of the vulnerability, maybe, you can also set up the network configuration with NixOS options. For example, to set up 2 VMs on different local networks and connect them with a router VM (CVE-2023-23915):

```nix
# client.nix
networking.defaultGateway.address = "192.168.1.1";

networking.interfaces.eth1.ipv4.addresses = lib.mkForce [
    { address = "192.168.1.2"; prefixLength = 24; }
];
# router.nix

virtualisation.vlans = [ 1 2 ];

networking.interfaces.eth1.ipv4.addresses = lib.mkForce [
    { address = "192.168.1.1"; prefixLength = 24; }
];
networking.interfaces.eth2.ipv4.addresses = lib.mkForce [
    { address = "192.168.2.1"; prefixLength = 24; }
];

boot.kernel.sysctl = {
    "net.ipv4.ip_forward" = 1;
    "net.ipv6.conf.all.forwarding" = 1;
};

networking.nat = {
    enable = true;
    externalInterface = "eth2";
    internalInterfaces = [ "eth1" ];
};

# server.nix
virtualisation.vlans = [ 2 ];
networking.defaultGateway.address = "192.168.2.1";
...
```

After forcefully assigning the IP addresses to the VMs with `networking.interfaces.<interface>.ipv4.addresses`, we set the virtual LANs for the interfaces ( `eth1` (1 by default) for the client and `eth2` (2) for the server) and configure the router to forward packets between the two subnets. This allows us to simulate a more realistic network environment.
