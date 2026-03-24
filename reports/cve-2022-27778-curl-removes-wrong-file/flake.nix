{
  description = "curl CVE case (library-backed)";

  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
  inputs.curlCveLib.url = "git+file:../..?dir=src";

  outputs = { self, nixpkgs, curlCveLib }:
    curlCveLib.lib.mkCurlCveCase {
      inherit nixpkgs;
      caseDir = ./.;
      system = "x86_64-linux";
    };
}
