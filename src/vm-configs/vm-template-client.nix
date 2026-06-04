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

  isRetrictNetwork = 
    if clientCfg ? internet_access then
      if !(clientCfg.internet_access == true || clientCfg.internet_access == false) then
        throw "Invalid value for internet_access configuration, expected boolean but got: ${toString clientCfg.internet_access}"
      else if clientCfg.internet_access then
        builtins.warn "Client VM is configured to have internet access which may cause unintended vulnerabilities to be exposed in the test environment." false
      else true
    else true;

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
        builtins.fetchTarball {
          url = tarballUrl;
          sha256 = "";
        };
      importedPkgs = import tarball { inherit system; };
      curlPkgs = if importedPkgs ? curlFull then importedPkgs.curlFull else importedPkgs.curl;
    in
      curlPkgs.override(
        lib.filterAttrs (k: v: v != null) {
          opensslSupport = 
            if info ? tls_backend then
              if info.tls_backend == "openssl" then true else if info.tls_backend != "wolfssl" && info.tls_backend != "gnutls" && info.tls_backend != "rustls" then throw "Unknown TLS backend specified in curl package configuration: ${info.tls_backend}" else false
            else null;
          wolfsslSupport = if info ? tls_backend && info.tls_backend == "wolfssl" then true else null;
          gnutlsSupport = if info ? tls_backend && info.tls_backend == "gnutls" then true else null;
          rustlsSupport = if info ? tls_backend && info.tls_backend == "rustls" then true else null;

          brotliSupport = if info ? with_brotli then info.with_brotli else null;
          c-aresSupport = if info ? with_ares then info.with_ares else null;
          gsaslSupport = if info ? with_gsasl then info.with_gsasl else null;
          http2Support = if info ? with_nghttp2 then info.with_nghttp2 else null;
          http3Support = if info ? with_http3 then info.with_http3 else null;
          websocketSupport = if info ? with_websocket then info.with_websocket else null;
          idnSupport = if info ? with_idn then info.with_idn else null;
          ldapSupport = if info ? with_ldap then info.with_ldap else null;
          pslSupport = if info ? with_psl then info.with_psl else null;
          rtmpSupport = if info ? with_rtmp then info.with_rtmp else null;
          scpSupport = if info ? with_scp then info.with_scp else null;
          zlibSupport = if info ? with_zlib then info.with_zlib else null;
          zstdSupport = if info ? with_zstd then info.with_zstd else null;
        }
      );

  curlVulnerable =
    if !(curlCfg ? strategy) then throw "Curl configuration must specify a strategy for obtaining the vulnerable curl version"
    else if curlCfg.strategy == "nixpkgs" && curlCfg ? package then mkCurlFromTarball curlCfg.package
    else if curlCfg.strategy == "source" && curlCfg ? package then 
      import ./custom-curl-source.nix {
        inherit pkgs;
        version = curlCfg.package.version;
        url = curlCfg.package.url;
        sha256 = curlCfg.package.hash;
        tlsBackend = curlCfg.package.tls_backend or "openssl";
        withNghttp2 = curlCfg.package.with_nghttp2 or true;
        withZlib = curlCfg.package.with_zlib or true;
        withLibpsl = curlCfg.package.with_libpsl or true;
        withBrotli = curlCfg.package.with_brotli or false;
        withZstd = curlCfg.package.with_zstd or false;
        withLibidn2 = curlCfg.package.with_libidn2 or false;
        enableShared = curlCfg.package.enable_shared or true;
        enableDebug = curlCfg.package.enable_debug or false;
        doCheck = curlCfg.package.do_check or false;
        disabledProtocols = curlCfg.package.disabled_protocols or [];
        disabledFeatures = curlCfg.package.disabled_features or [];
        extraConfigureFlags = curlCfg.package.extra_configure_flags or [];
      }
    else if curlCfg.strategy != "custom" then throw "Invalid curl configuration strategy or missing package information"
    else null;

  # curlPatched =
  #   if curlCfg.strategy == "nixpkgs"
  #   then mkCurlFromTarball curlCfg.patched
  #   else pkgs.curlFull;

  # User provided client application in case of library vulnerability
  clientAppCfg = if curlVulnerable != null && curlCfg.target == "library" then clientCfg.application or {} else {};
  # clientAppOutput = if clientAppCfg ? build_output then clientAppCfg.build_output else "client-app";
  curlPkgs = curlVulnerable;
  clientApp = if curlCfg.target == "library" && clientAppCfg != {} then pkgs.stdenv.mkDerivation {
    pname = "vulnerable-client";
    version = "1.0";
    src = if clientAppCfg ? file_path then "${caseDir}/${clientAppCfg.file_path}" else "${caseDir}/exploit/client";
    buildInputs = [ pkgs.gcc curlPkgs ];
    buildPhase = 
      let
        buildConfig = if clientAppCfg ? build_config then clientAppCfg.build_config else throw "client application configuration requires 'build_config' to be specified";
        buildFile = if buildConfig ? source_file then "${buildConfig.source_file}" else throw "client application build configuration requires 'source_file' to be specified";
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
    inherit isTest isRetrictNetwork;
    hostName = "client";
    fixedConfig = {
      environment.systemPackages = [ ] 
      ++ (if curlVulnerable != null then [ curlVulnerable ] else [])
      ++ (if startClientScript != null then [ startClientScript ] else []);
      # ++ (if isVulnerable then [ curlVulnerable ] else [ curlPatched ]);
    };
    customConfig = customClientConfig;
  }) { inherit config pkgs lib modulesPath; }