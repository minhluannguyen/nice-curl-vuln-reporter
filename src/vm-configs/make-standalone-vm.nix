{ configPath, extraArgs ? {}, nixpkgs, ... }:

let
  mkVm = system:
    (import "${nixpkgs}/nixos" {
      configuration = import configPath (extraArgs // { isTest = false; });
      inherit system;
    }).config.system.build.vm;
in
{
  system = {
    "x86_64" = mkVm "x86_64-linux";
    "arm" = mkVm "aarch64-linux";
  };
}