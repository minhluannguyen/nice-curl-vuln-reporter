{
  description = "Run a Python script with nix run";

  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";

  outputs = { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      packages = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; };

          packagedPython = pkgs.python312.withPackages (ps: with ps; [
            jinja2
            pyyaml
            pexpect
          ]);

          nice-report = pkgs.writeShellScriptBin "nice-report" ''
            export PATH=${pkgs.nix}/bin:${pkgs.terminator}/bin:${pkgs.openssh}/bin:$PATH
            exec ${packagedPython}/bin/python ${self}/nice-report.py "$@"
          '';
        in
        {
          inherit nice-report;
          default = nice-report;
        });

      apps = forAllSystems (system: {
        nice-report = {
          type = "app";
          program = "${self.packages.${system}.nice-report}/bin/nice-report";
        };
        default = self.apps.${system}.nice-report;
      });
    };
}