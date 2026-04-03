{ isTest, customMachineCfg, hostname, caseDir }:
{ config, pkgs, lib, modulesPath, ... }:

let
  configPath = if customMachineCfg ? config_path then caseDir + "/${customMachineCfg.config_path}" else null;
  defaultConfigPath = caseDir + "/vm-configs/${hostname}.nix";
  effectiveConfigPath = 
    if configPath != null && builtins.pathExists configPath then configPath
    else if builtins.pathExists defaultConfigPath then defaultConfigPath
    else null;
  customMachineConfig = if effectiveConfigPath != null then import effectiveConfigPath { inherit config pkgs lib; } else {};

  diskImagePath = if customMachineCfg ? disk_image_path then "/${customMachineCfg.disk_image_path}" else null;
  isRetrictNetwork = 
    if customMachineCfg ? internet_access then
      if !(customMachineCfg.internet_access == true || customMachineCfg.internet_access == false) then
        throw "Invalid value for internet_access configuration, expected boolean but got: ${toString customMachineCfg.internet_access}"
      else if customMachineCfg.internet_access then
        builtins.warn "VM ${hostname} is configured to have internet access which may cause unintended vulnerabilities to be exposed in the test environment." false
      else true
    else true;

  # Networking configuration
  normalizePorts = ports: if builtins.isList ports then ports else [ ports ];
  allowedTCPPortsRaw =
    if customMachineCfg ? networking && customMachineCfg.networking ? allowed_tcp_ports then customMachineCfg.networking.allowed_tcp_ports
    else null;
  allowedTCPPorts = if allowedTCPPortsRaw == null then [] else normalizePorts allowedTCPPortsRaw;
in
  (import ./vm-template-instance.nix {
    inherit isTest diskImagePath isRetrictNetwork;
    hostName = hostname;
    fixedConfig = {
      networking.firewall.allowedTCPPorts = allowedTCPPorts;
    };
    customConfig = customMachineConfig;
  }) { inherit config pkgs lib modulesPath; }