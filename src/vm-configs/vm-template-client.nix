{ isVulnerable, isTest, clientCfg, curlCfg, caseDir }:
{ config, pkgs, lib, modulesPath, ... }:

let
  system = pkgs.stdenv.hostPlatform.system;
  configPath = if clientCfg ? config_path then caseDir + "/${clientCfg.config_path}" else null;
  customClientConfig = if configPath != null then import configPath { inherit config pkgs lib; } else {};
  normalizePorts = ports: if builtins.isList ports then ports else [ ports ];

  outboundGuestPortsRaw =
    if clientCfg ? outbound_guest_ports then clientCfg.outbound_guest_ports
    else if clientCfg ? outbound_guest_port then clientCfg.outbound_guest_port
    else null;

  outboundHostPortsRaw =
    if clientCfg ? outbound_host_ports then clientCfg.outbound_host_ports
    else if clientCfg ? outbound_host_port then clientCfg.outbound_host_port
    else null;

  outboundGuestPorts = if outboundGuestPortsRaw == null then [] else normalizePorts outboundGuestPortsRaw;
  outboundHostPorts = if outboundHostPortsRaw == null then [] else normalizePorts outboundHostPortsRaw;

  mkCurlFromTarball = info:
    let
      importedPkgs = import (builtins.fetchTarball {
        url = info.nixpkgs_url;
        sha256 = info.nixpkgs_sha256;
      }) { inherit system; };
    in
      if importedPkgs ? curlFull then importedPkgs.curlFull else importedPkgs.curl;

  mkCurlCustom = src:
    pkgs.stdenv.mkDerivation ({
      name = "curl-${src.version}";
      src = builtins.fetchurl ({ url = src.url; } //
        (if src ? sha256 then { sha256 = src.sha256; }
         else if src ? hash then { sha256 = src.hash; }
         else throw "curl.custom_src requires either sha256 or hash"));
      buildInputs = [ pkgs.zlib ];
      configureFlags = [ "--host=x86_64-pc-linux-gnu" "--without-ssl" ];
      CFLAGS = src.cflags or "";
    } // lib.optionalAttrs (src.disable_hardening or false) {
      hardeningDisable = [ "all" ];
    });

  curlVulnerable =
    if curlCfg.nixpkgs_strategy == "tarball"
    then mkCurlFromTarball curlCfg.vulnerable
    else mkCurlCustom curlCfg.custom_src;

  curlPatched =
    if curlCfg.nixpkgs_strategy == "tarball"
    then mkCurlFromTarball curlCfg.patched
    else pkgs.curlFull;
in
  (import ./vm-template-instance.nix {
    inherit isTest;
    fixedConfig = {
      virtualisation.forwardPorts =
        if isTest || outboundGuestPorts == [] || outboundHostPorts == [] then
          []
        else if builtins.length outboundGuestPorts != builtins.length outboundHostPorts then
          throw "client outbound_guest_ports and outbound_host_ports must have the same number of entries"
        else
          builtins.genList
            (index: {
              from = "guest";
              guest.address = clientCfg.outbound_guest_address or "10.0.2.10";
              guest.port = builtins.elemAt outboundGuestPorts index;
              host.address = "127.0.0.1";
              host.port = builtins.elemAt outboundHostPorts index;
            })
            (builtins.length outboundGuestPorts);
      environment.systemPackages = [ pkgs.code ] ++ (if isVulnerable then [ curlVulnerable ] else [ curlPatched ]);
    };
      hostName = "client";
    customConfig = customClientConfig;
  }) { inherit config pkgs lib modulesPath; }