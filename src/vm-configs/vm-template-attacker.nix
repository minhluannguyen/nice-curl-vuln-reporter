{ isTest, attackerCfg, caseDir, mkEscapedCommand }:
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

  diskImagePath = if attackerCfg ? disk_image_path then "/${attackerCfg.disk_image_path}" else null;
  isRetrictNetwork = 
    if attackerCfg ? internet_access then
      if !(attackerCfg.internet_access == true || attackerCfg.internet_access == false) then
        throw "Invalid value for internet_access configuration, expected boolean but got: ${toString attackerCfg.internet_access}"
      else if attackerCfg.internet_access then
        builtins.warn "Attacker VM is configured to have internet access which may cause unintended vulnerabilities to be exposed in the test environment." false
      else true
    else true;

  # Network port configuration
  normalizePorts = ports: if builtins.isList ports then ports else [ ports ];
  allowedTCPPortsRaw =
    if attackerCfg ? networking && attackerCfg.networking ? allowed_tcp_ports then attackerCfg.networking.allowed_tcp_ports
    else null;
  allowedTCPPorts = if allowedTCPPortsRaw == null then [] else normalizePorts allowedTCPPortsRaw;
  
  # Server configuration for the attacker VM
  hasServerConfig = attackerCfg ? server;
  serverCfg = if hasServerConfig then attackerCfg.server else {};
  
  serverFilePath = if serverCfg ? file_path then caseDir + "/${serverCfg.file_path}" else caseDir + "/exploit/server";
  
  serverFiles = pkgs.runCommand "server-files" { } ''
    mkdir -p $out
    cp -r ${serverFilePath} $out/exploit
  '';

  # If C server
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

  # If Python server
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

  # If shell server
  requiredPackagesList = if hasServerConfig && serverCfg.language == "shell" && serverCfg ? required_packages then serverCfg.required_packages else [];
  requiredPackages = map (pkg: pkgs.${pkg}) requiredPackagesList;
  
  shellServerWithEnv = if hasServerConfig && serverCfg.language == "shell" && serverCfg ? run_command then
    let
      shellEnv = pkgs.buildEnv {
        name = "shell-server-env";
        paths = requiredPackages;
      };
    in
      pkgs.writeShellScript "shell-server-inner" ''
        export PATH="${shellEnv}/bin:$PATH"
        cd ${serverFiles}/exploit
        ${serverCfg.run_command}
      ''
  else null;

  # Generate a start script for the server 
  startServerScript = if hasServerConfig && serverCfg ? run_command then
    pkgs.writeScriptBin "start-server" ''
    #!${pkgs.bash}/bin/bash
    ${if serverCfg ? run_command then 
        if serverCfg.language == "c" then "cd ${serverDerivation}/exploit && ./${mkEscapedCommand serverCfg.run_command}" else
          if serverCfg.language == "python" then "cd ${serverFiles}/exploit && ${modifiedPyPkgs}/bin/${mkEscapedCommand serverCfg.run_command}" else
            if serverCfg.language == "shell" then "${shellServerWithEnv}" else ""
    else "" } 
    ''
  else null;
in
  (import ./vm-template-instance.nix {
    inherit isTest diskImagePath isRetrictNetwork;
    hostName = "attacker";
    fixedConfig = {
      networking.firewall.allowedTCPPorts = allowedTCPPorts;
      environment.systemPackages = 
        with pkgs;[ python3 gcc ] 
        ++ (if hasServerConfig then [ startServerScript ] else []);
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