{ isTest, customMachineCfg, hostname, caseDir }:
{ config, pkgs, lib, modulesPath, ... }:

let
  configPath = if customMachineCfg ? config_path then caseDir + "/${customMachineCfg.config_path}" else null;
  customMachineConfig = if configPath != null then import configPath { inherit config pkgs lib; } else {};
  normalizePorts = ports: if builtins.isList ports then ports else [ ports ];

  outboundGuestPortsRaw =
    if customMachineCfg ? outbound_guest_ports then customMachineCfg.outbound_guest_ports
    else if customMachineCfg ? outbound_guest_port then customMachineCfg.outbound_guest_port
    else null;

  outboundHostPortsRaw =
    if customMachineCfg ? outbound_host_ports then customMachineCfg.outbound_host_ports
    else if customMachineCfg ? outbound_host_port then customMachineCfg.outbound_host_port
    else null;

  inboundGuestPortsRaw =
    if customMachineCfg ? inbound_guest_ports then customMachineCfg.inbound_guest_ports
    else if customMachineCfg ? inbound_guest_port then customMachineCfg.inbound_guest_port 
    else null;

  inboundHostPortsRaw =
    if customMachineCfg ? inbound_host_ports then customMachineCfg.inbound_host_ports
    else if customMachineCfg ? inbound_host_port then customMachineCfg.inbound_host_port
    else null;

  outboundGuestPorts = if outboundGuestPortsRaw == null then [] else normalizePorts outboundGuestPortsRaw;
  outboundHostPorts = if outboundHostPortsRaw == null then [] else normalizePorts outboundHostPortsRaw;
  inboundGuestPorts = if inboundGuestPortsRaw == null then [] else normalizePorts inboundGuestPortsRaw;
  inboundHostPorts = if inboundHostPortsRaw == null then [] else normalizePorts inboundHostPortsRaw;
in
  (import ./vm-template-instance.nix {
    inherit isTest;
    hostName = hostname;
    fixedConfig = {
      virtualisation.forwardPorts =
        (if isTest || outboundGuestPorts == [] || outboundHostPorts == [] then
          []
        else if builtins.length outboundGuestPorts != builtins.length outboundHostPorts then
          throw "custom VM outbound_guest_ports and outbound_host_ports must have the same number of entries"
        else
          builtins.genList
            (index: {
              from = "guest";
              guest.address = customMachineCfg.outbound_guest_address or "10.0.2.10";
              guest.port = builtins.elemAt outboundGuestPorts index;
              host.address = customMachineCfg.outbound_host_address or "127.0.0.1";
              host.port = builtins.elemAt outboundHostPorts index;
            })
            (builtins.length outboundGuestPorts))
        ++
        (if isTest || inboundGuestPorts == [] || inboundHostPorts == [] then
          []
        else if builtins.length inboundGuestPorts != builtins.length inboundHostPorts then
          throw "custom VM inbound_guest_ports and inbound_host_ports must have the same number of entries"
        else
          builtins.genList
            (index: {
              from = "host";
              host.port = builtins.elemAt inboundHostPorts index;
              guest.port = builtins.elemAt inboundGuestPorts index;
            })
            (builtins.length inboundGuestPorts));

      networking.firewall.allowedTCPPorts = inboundGuestPorts;
    };
    customConfig = customMachineConfig;
  }) { inherit config pkgs lib modulesPath; }