{ isTest, hostName, fixedConfig, customConfig }:
{ config, pkgs, lib, modulesPath, ... }:

let
  template = (import ./vm-minimal.nix { inherit isTest hostName; }) { inherit pkgs lib modulesPath; };

  mergeConfig = a: b:
    if builtins.isAttrs a && builtins.isAttrs b then
      builtins.mapAttrs
        (name: _: mergeConfig (a.${name} or null) (b.${name} or null))
        (a // b)
    else if builtins.isList a && builtins.isList b then
      a ++ b
    else if b != null then
      b
    else
      a;
in
  mergeConfig template (mergeConfig fixedConfig customConfig)