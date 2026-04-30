{
  description = "Run a Python script with nix run";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

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

          python = pkgs.python312.withPackages (ps: with ps; [
            jinja2
            pyyaml
            pexpect
          ]);

          runtimeInputs = [ python pkgs.terminator pkgs.openssh ];

          nice-report = pkgs.writeShellScriptBin "nice-report" ''
            exec ${python}/bin/python ${self}/nice-report.py "$@"
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