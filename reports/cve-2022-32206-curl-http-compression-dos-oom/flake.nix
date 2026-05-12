{
  description = "A NICE curl vulnerability report flake";

  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
  inputs.curlCveLib.url = "github:minhluannguyen/nice-curl-vuln-reporter?dir=src";

  outputs = { self, nixpkgs, curlCveLib }:
    curlCveLib.lib.mkCurlCveCase {
      inherit nixpkgs;
      caseDir = ./.;
      system = "x86_64-linux";
    };
}
