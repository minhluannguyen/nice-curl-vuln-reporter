# Reporting Guide for NICE cURL Vulnerability Reports

This document provides notes and guidelines for writing vulnerability reports using the NICE cURL Vulnerability Report framework.

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

Nix approach values reproducibility and transparency, so it requires the exact version and hash of the `curl` package to be predefined. The provided CLI tool can help you fetch the correct hash for the `curl` automatically after the report template is generated or whenever you select the "Update hashes for existing report" option in the CLI tool.

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

Refer to the above documentation for the configuration of the VMs. If more services are needed, you can add them in `vm-configs/` and create new VM configurations.

The file name should be exactly the same as the name of the VM specified in the YAML report. Based on the similarity of the curl vulnerability, there are two VMs provided as templates:
- `client`: in majority of the cases, the vulnerable `curl` is running on the client side. `curl` will be automatically installed on this VM based on the `curl` details specified in the report YAML file. In case of libcurl vulnerabilities, it allows an clien curl application to be set up on this VM.
- `attacker`: if the `attack-vector` sets to `remote`, an attacker VM will be set up to simulate the remote attack. This VM allows the user to set up a malicious server to exploit the vulnerability.

Many services, software are available as [NixOS options](https://search.nixos.org/options). For example, this is how the OpenSMTPD service is set up in the server VM configuration file:

```nix
# Set up OpenSMTPD service
  services.opensmtpd.enable = true;
  services.opensmtpd.package = opensmtpdPkgs;
  services.opensmtpd.serverConfiguration = ''
    #       $OpenBSD: smtpd.conf,v 1.10 2018/05/24 11:40:17 gilles Exp $

    # This is the smtpd server system-wide configuration file.
    # See smtpd.conf(5) for more information.

    # table aliases file:/etc/aliases
    table aliases file:/dev/null

    # To accept external mail, replace with: listen on all
    #
    listen on "0.0.0.0"

    action "local" mbox alias <aliases>
    action "relay" relay

    # Uncomment the following to accept external mail for domain "example.org"
    #
    match from any for domain "example.org" action "local"
    match for local action "local"
    match from local for any action "relay"
  '';
```

An example of setting up a malicious server on the attacker VM that requires Python and its external package `pwntools` to be installed:
```nix
let
    # Create a modified Python package set with the required external packages
    modifiedPyPkgs = pkgs.python3.withPackages (python-pkgs: [
        python-pkgs.pwntools
    ]);

    # Create a package for the server files (copy the server files to the output directory)
    serverFiles = pkgs.runCommand "server-files" { } ''
        mkdir -p $out
        cp -r ${./exploit/server} $out/exploit
    '';

    # Create a script to start the server
    startServerScript = pkgs.writeScriptBin "start-server" ''
        #!${pkgs.bash}/bin/bash

        cd ${serverFiles}
        ${modifiedPyPkgs}/bin/python3 ${serverFiles}/exploit/exploit-server.py
    '';
in
{
    # Add required packages to the system environment
    environment.systemPackages = with pkgs; [ 
        bashInteractive
        coreutils
        modifiedPyPkgs
        serverFiles
        startServerScript
    ];

    # Open the required port for the server
    networking.firewall.allowedTCPPorts = [ 1337 ];

    # Set up a systemd service to start the server on boot
    systemd.services = {
        wsServerSetup = {
        description = "WebSocket server setup";
        wantedBy = [ "multi-user.target" ];
        after = [ "network.target" ];
        path = [ startServerScript ];
        script = ''
            start-server 2>&1
        '';
        };
    };
}
```

It is also possible to compile source code and then be used in the VMs:
```nix
let
    clientApp = pkgs.stdenv.mkDerivation {
        pname = "vulnerable-client";
        version = "1.0";
        src = ./exploit/client;
        buildInputs = [ curlPkgs ];
        buildPhase = ''
            gcc vulnerable-client-original.c -o ws-client $(curl-config --cflags --libs) -O0 -fsanitize=address,undefined
        '';
        installPhase = ''
            mkdir -p $out/bin
            cp ws-client $out/bin/
        '';
    };

    startClientScript = pkgs.writeScriptBin "start-client" ''
        #!${pkgs.bash}/bin/bash
        ${clientApp}/bin/ws-client "$@"
    '';
in
{
    environment.systemPackages = with pkgs; [
        ...
        startClientScript
  ];
}
```

And then later in the test scenarios or manual interactive session, you can simply run `start-client --url <URL>` to execute the vulnerable client application.

### Write test scenarios

The YAML report provides an abstract layer to the original NixOS test framework, which allows users to write test scenarios for NixOS VM. It handles the setting up of the VMs and utilizes assertion blocks to check the expected behavior of the vulnerability exploitation, allowing reviewers to easily understand the vulnerability in a more declarative way.

You can rewrite the test scenarios with a `test-script.py` file but it is recommended to use the YAML report file for better readability and maintainability. Refer to the [NixOS Testing Framework](https://nixos.wiki/wiki/NixOS_Testing_library) and [its syntax](https://nixos.org/manual/nixos/stable/index.html#sec-nixos-tests) for the complete description of the NixOS test framework.