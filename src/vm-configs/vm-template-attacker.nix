{ isTest, attackerCfg, caseDir }:
{ config, pkgs, lib, modulesPath, ... }:

let
  # Additional configuration layers for the attacker VM, added by the user
  configPath = if attackerCfg ? config_path then caseDir + "/${attackerCfg.config_path}" else null;
  defaultConfigPath = caseDir + "/vm-configs/attacker.nix";
  effectiveConfigPath = 
    if configPath != null && builtins.pathExists configPath then configPath
    else if builtins.pathExists defaultConfigPath then defaultConfigPath
    else null;
  customAttackerConfig = if effectiveConfigPath != null then import effectiveConfigPath { inherit config pkgs lib; } else {};
  
  # Network port configuration
  normalizePorts = ports: if builtins.isList ports then ports else [ ports ];

  inboundGuestPortsRaw =
    if attackerCfg ? networking && attackerCfg.networking ? inbound_guest_ports then attackerCfg.networking.inbound_guest_ports
    else null;

  inboundHostPortsRaw =
    if attackerCfg ? networking && attackerCfg.networking ? inbound_host_ports then attackerCfg.networking.inbound_host_ports
    else null;

  inboundGuestPorts = if inboundGuestPortsRaw == null then [] else normalizePorts inboundGuestPortsRaw;
  inboundHostPorts = if inboundHostPortsRaw == null then [] else normalizePorts inboundHostPortsRaw;

  # Server configuration for the attacker VM
  hasServerConfig = attackerCfg ? server;
  serverCfg = if hasServerConfig then attackerCfg.server else {};
  
  serverFilePath = if serverCfg ? file_path then caseDir + "/${serverCfg.file_path}" else caseDir + "/exploit/server";
  
  serverFiles = pkgs.runCommand "server-files" { } ''
    mkdir -p $out
    cp -r ${serverFilePath} $out/exploit
  '';

  serverDerivation = if serverCfg ? build_config && serverCfg.language == "c" then
    pkgs.stdenv.mkDerivation {
      name = "malicious-server";
      version = "1.0";
      src = serverFiles + "/exploit";
      nativeBuildInputs = if serverCfg.build_config ? build_inputs && (serverCfg.build_config.build_inputs == "gcc") then [ pkgs.gcc ] else [];
      
      buildPhase = if serverCfg.build_config ? build_commands then serverCfg.build_config.build_commands else null;

      installPhase = ''
        mkdir -p $out/exploit
        cp ${if serverCfg.build_config ? build_output then serverCfg.build_config.build_output else "server"} $out/exploit/
      '';
    }
  else null;

  pythonVersionPkg = if hasServerConfig && serverCfg.language == "python" then
    if serverCfg ? python_version then
      let
        versionStr = toString serverCfg.python_version;
        versionAttr = "python${lib.replaceStrings [ "." ] [ "" ] versionStr}";
      in
        if pkgs ? ${versionAttr} then pkgs.${versionAttr} else pkgs.python3
    else pkgs.python3
  else null;

  modifiedPyPkgs = if hasServerConfig && serverCfg.language == "python" then
    if serverCfg ? python_packages then 
      pythonVersionPkg.withPackages (pythonPkgs: 
        map (pkg: pythonPkgs.${pkg}) serverCfg.python_packages
      )
    else pythonVersionPkg
  else null;

  startServerScript = if hasServerConfig && serverCfg ? run_command then
    pkgs.writeScriptBin "start-server" ''
    #!${pkgs.bash}/bin/bash
    ${if serverCfg ? run_command then 
        if serverCfg.language == "c" then "cd ${serverDerivation}/exploit && ./${serverCfg.run_command}" else
          if serverCfg.language == "python" then "cd ${serverFiles}/exploit && ${modifiedPyPkgs}/bin/${serverCfg.run_command}" else ""
    else ""} 
    ''
  else null;
in
  (import ./vm-template-instance.nix {
    inherit isTest;
    hostName = "attacker";
    fixedConfig = {
      virtualisation.forwardPorts =
        if isTest || inboundGuestPorts == [] || inboundHostPorts == [] then
          []
        else if builtins.length inboundGuestPorts != builtins.length inboundHostPorts then
          throw "attacker inbound_guest_ports and inbound_host_ports must have the same number of entries ${toString inboundGuestPorts} vs ${toString inboundHostPorts}"
        else
          builtins.genList
            (index: {
              from = "host";
              host.port = builtins.elemAt inboundHostPorts index;
              guest.port = builtins.elemAt inboundGuestPorts index;
            })
            (builtins.length inboundGuestPorts);
      
      networking.firewall.allowedTCPPorts = inboundGuestPorts;

      environment.systemPackages = with pkgs;[ python3 gcc ] ++ (if hasServerConfig then [ startServerScript ] else []);

      systemd.services = if hasServerConfig then {
        maliciousServer = {
          description = "Malicious Server";
          wantedBy = [ "multi-user.target" ];
          path = [ startServerScript ];
          script = ''
            start-server 2>&1
          '';
        };
      } else {};
    };
    customConfig = customAttackerConfig;
  }) { inherit config pkgs lib modulesPath; }