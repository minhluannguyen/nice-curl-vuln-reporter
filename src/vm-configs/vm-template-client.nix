{ isVulnerable, isTest, clientCfg, curlCfg, caseDir }:
{ config, pkgs, lib, modulesPath, ... }:

let
  system = pkgs.stdenv.hostPlatform.system;
  configPath = if clientCfg ? config_path then caseDir + "/${clientCfg.config_path}" else null;
  defaultConfigPath = caseDir + "/vm-configs/client.nix";
  effectiveConfigPath = 
    if configPath != null && builtins.pathExists configPath then configPath
    else if builtins.pathExists defaultConfigPath then defaultConfigPath
    else null;
  customClientConfig = if effectiveConfigPath != null then import effectiveConfigPath { inherit config pkgs lib; } else {};

  normalizePorts = ports: if builtins.isList ports then ports else [ ports ];

  outboundGuestPortsRaw =
    if clientCfg ? networking && clientCfg.networking ? outbound_guest_ports then clientCfg.networking.outbound_guest_ports
    else null;

  outboundHostPortsRaw =
    if clientCfg ? networking && clientCfg.networking ? outbound_host_ports then clientCfg.networking.outbound_host_ports
    else null;

  outboundGuestPorts = if outboundGuestPortsRaw == null then [] else normalizePorts outboundGuestPortsRaw;
  outboundHostPorts = if outboundHostPortsRaw == null then [] else normalizePorts outboundHostPortsRaw;

  mkCurlFromTarball = info:
    let
      tarballUrl = "https://github.com/NixOS/nixpkgs/archive/${info.commit}.tar.gz";
      tarball = if info ? sha256 && info.sha256 != null then
        builtins.fetchTarball {
          url = tarballUrl;
          sha256 = info.sha256;
        }
      else
        # In --impure mode
        # builtins.fetchTarball tarballUrl;
        builtins.fetchTarball {
          url = tarballUrl;
          sha256 = "";
        };
      importedPkgs = import tarball { inherit system; };
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
    if curlCfg.strategy == "nixpkgs"
    then mkCurlFromTarball curlCfg.vulnerable
    else if curlCfg.strategy == "custom" && curlCfg.custom_src != null
    then mkCurlCustom curlCfg.custom_src
    else throw "Invalid curl configuration strategy or missing custom_src for custom strategy";

  # curlPatched =
  #   if curlCfg.strategy == "nixpkgs"
  #   then mkCurlFromTarball curlCfg.patched
  #   else pkgs.curlFull;
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
      environment.systemPackages = [ pkgs.code ] 
      ++ ([ curlVulnerable ]);
      # ++ (if isVulnerable then [ curlVulnerable ] else [ curlPatched ]);
    };
      hostName = "client";
    customConfig = customClientConfig;
  }) { inherit config pkgs lib modulesPath; }