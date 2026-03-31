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

  # networking configuration
  normalizePorts = ports: if builtins.isList ports then ports else [ ports ];

  outboundGuestPortsRaw =
    if clientCfg ? networking && clientCfg.networking ? outbound_guest_ports then clientCfg.networking.outbound_guest_ports
    else null;

  outboundHostPortsRaw =
    if clientCfg ? networking && clientCfg.networking ? outbound_host_ports then clientCfg.networking.outbound_host_ports
    else null;

  outboundGuestPorts = if outboundGuestPortsRaw == null then [] else normalizePorts outboundGuestPortsRaw;
  outboundHostPorts = if outboundHostPortsRaw == null then [] else normalizePorts outboundHostPortsRaw;

  # Fetch curl package from provided nixpkgs commit
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

  curlVulnerable =
    if curlCfg ? strategy && curlCfg.strategy == "nixpkgs" && curlCfg ? package then mkCurlFromTarball curlCfg.package
    else if curlCfg ? strategy && curlCfg.strategy == "source" && curlCfg ? package then 
      import ./custom-curl-source.nix {
        inherit pkgs;
        version = curlCfg.package.version;
        url = curlCfg.package.url;
        sha256 = curlCfg.package.sha256;
        tlsBackend = curlCfg.package.tls_backend or "openssl";
        withZlib = curlCfg.package.with_zlib or true;
        withLibpsl = curlCfg.package.with_libpsl or true;
        withBrotli = curlCfg.package.with_brotli or false;
        withZstd = curlCfg.package.with_zstd or false;
        withLibidn2 = curlCfg.package.with_libidn2 or false;
        withNghttp2 = curlCfg.package.with_nghttp2 or false;
        enableShared = curlCfg.package.enable_shared or true;
        enableDebug = curlCfg.package.enable_debug or false;
        doCheck = curlCfg.package.do_check or false;
        disabledProtocols = curlCfg.package.disabled_protocols or [];
        disabledFeatures = curlCfg.package.disabled_features or [];
        extraConfigureFlags = curlCfg.package.extra_configure_flags or [];
      }
    else throw "Invalid curl configuration strategy or missing package information";

  # curlPatched =
  #   if curlCfg.strategy == "nixpkgs"
  #   then mkCurlFromTarball curlCfg.patched
  #   else pkgs.curlFull;

  # User provided client application in case of library vulnerability
  clientAppCfg = if clientCfg ? application then clientCfg.application else {};
  # clientAppOutput = if clientAppCfg ? build_output then clientAppCfg.build_output else "client-app";
  curlPkgs = curlVulnerable;
  clientApp = if curlCfg.target == "library" then pkgs.stdenv.mkDerivation {
    pname = "vulnerable-client";
    version = "1.0";
    src = if clientAppCfg ? file_path then "${caseDir}/${clientAppCfg.file_path}" else "${caseDir}/exploit/client";
    buildInputs = [ pkgs.gcc curlPkgs ];
    buildPhase = 
      let
        buildConfig = if clientAppCfg ? build_config then clientAppCfg.build_config else throw "client application configuration requires 'build_config' to be specified";
        buildFile = if buildConfig ? build_file then "${buildConfig.build_file}" else throw "client application build configuration requires 'build_file' to be specified";
        buildFlags = if buildConfig ? build_flags && buildConfig.build_flags != null then "${buildConfig.build_flags}" else "";
      in ''
        gcc ${buildFile} -o client-app $(curl-config --cflags --libs) ${buildFlags}
      '';
    installPhase = ''
      mkdir -p $out/bin
      cp client-app $out/bin/
    '';
  } else null;

  startClientScript = if clientApp != null then pkgs.writeScriptBin "start-client" ''
    #!${pkgs.bash}/bin/bash

    ${clientApp}/bin/client-app "$@"
  '' else null;
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
              guest.address = clientCfg.networking.outbound_guest_address or "10.0.2.10";
              guest.port = builtins.elemAt outboundGuestPorts index;
              host.address = "127.0.0.1";
              host.port = builtins.elemAt outboundHostPorts index;
            })
            (builtins.length outboundGuestPorts);
      environment.systemPackages = [ pkgs.code ] 
      ++ ([ curlVulnerable ])
      ++ (if startClientScript != null then [ startClientScript ] else []);
      # ++ (if isVulnerable then [ curlVulnerable ] else [ curlPatched ]);
    };
      hostName = "client";
    customConfig = customClientConfig;
  }) { inherit config pkgs lib modulesPath; }