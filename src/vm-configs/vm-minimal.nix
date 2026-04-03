{ isTest, hostName, diskImagePath, isRetrictNetwork ? true }:
{ pkgs, lib, modulesPath, ... }:

let
  
in
{
  imports = if !isTest then
    [ "${modulesPath}/virtualisation/qemu-vm.nix" ]
  else [];

  system.stateVersion = "24.09";

  virtualisation.graphics = false;

  virtualisation.diskImage = if diskImagePath != null then "${diskImagePath}" else null;

  virtualisation.restrictNetwork = isRetrictNetwork;

  networking.hostName = hostName;

  environment.systemPackages = with pkgs; [ 
    bashInteractive
    coreutils
  ];

  users.users.root = {
    isSystemUser = true;
    password = if !isTest then "root" else null;
  };
}
