{ isTest, attackerCfg, caseDir }:
{ config, pkgs, lib, modulesPath, ... }:

let
  configPath = if attackerCfg ? config_path then caseDir + "/${attackerCfg.config_path}" else null;
  defaultConfigPath = caseDir + "/vm-configs/attacker.nix";
  effectiveConfigPath = 
    if configPath != null && builtins.pathExists configPath then configPath
    else if builtins.pathExists defaultConfigPath then defaultConfigPath
    else null;
  customAttackerConfig = if effectiveConfigPath != null then import effectiveConfigPath { inherit config pkgs lib; } else {};
  
  normalizePorts = ports: if builtins.isList ports then ports else [ ports ];

  inboundGuestPortsRaw =
    if attackerCfg ? inbound_guest_ports then attackerCfg.inbound_guest_ports
    else if attackerCfg ? inbound_guest_port then attackerCfg.inbound_guest_port
    else null;

  inboundHostPortsRaw =
    if attackerCfg ? inbound_host_ports then attackerCfg.inbound_host_ports
    else if attackerCfg ? inbound_host_port then attackerCfg.inbound_host_port
    else null;

  inboundGuestPorts = if inboundGuestPortsRaw == null then [] else normalizePorts inboundGuestPortsRaw;
  inboundHostPorts = if inboundHostPortsRaw == null then [] else normalizePorts inboundHostPortsRaw;
in
  (import ./vm-template-instance.nix {
    inherit isTest;
    hostName = "attacker";
    fixedConfig = {
      virtualisation.forwardPorts =
        if isTest || inboundGuestPorts == [] || inboundHostPorts == [] then
          []
        else if builtins.length inboundGuestPorts != builtins.length inboundHostPorts then
          throw "attacker inbound_guest_ports and inbound_host_ports must have the same number of entries"
        else
          builtins.genList
            (index: {
              from = "host";
              host.port = builtins.elemAt inboundHostPorts index;
              guest.port = builtins.elemAt inboundGuestPorts index;
            })
            (builtins.length inboundGuestPorts);
      networking.firewall.allowedTCPPorts = inboundGuestPorts;
    };
    customConfig = customAttackerConfig;
  }) { inherit config pkgs lib modulesPath; }