{
  description = "Nix package and NixOS module for Wazuh MCP Server";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        overlays = [ self.overlays.default ];
      };
      inherit (pkgs) lib;
    in
    {
      overlays.default = final: prev: {
        pythonPackagesExtensions = prev.pythonPackagesExtensions ++ [
          (pyFinal: _pyPrev: {
            gcf-python = pyFinal.callPackage ./nix/pkgs/gcf-python.nix { };
          })
        ];
        wazuh-mcp-server = final.callPackage ./nix/pkgs/wazuh-mcp-server.nix {
          inherit (final.python3Packages) gcf-python;
        };
      };

      packages.${system} = {
        inherit (pkgs) wazuh-mcp-server;
        gcf-python = pkgs.python3Packages.gcf-python;
        default = pkgs.wazuh-mcp-server;
      };

      nixosModules = {
        wazuh-mcp-server = ./nix/module.nix;
        default = self.nixosModules.wazuh-mcp-server;
      };

      checks.${system} = {
        inherit (pkgs) wazuh-mcp-server;
        gcf-python = pkgs.python3Packages.gcf-python;
        nixos = pkgs.testers.runNixOSTest (import ./nix/tests/wazuh-mcp-server.nix { inherit self; });

        # Lint the GitHub Actions workflows and the update script.
        lint =
          pkgs.runCommand "wazuh-mcp-lint"
            {
              nativeBuildInputs = [
                pkgs.actionlint
                pkgs.shellcheck
              ];
              src = lib.fileset.toSource {
                root = ./.;
                fileset = lib.fileset.unions [
                  ./.github
                  ./nix/update.sh
                ];
              };
            }
            ''
              cd $src
              actionlint -shellcheck=${lib.getExe pkgs.shellcheck} .github/workflows/*.yml
              shellcheck nix/update.sh
              touch $out
            '';
      };

      apps.${system}.default = {
        type = "app";
        program = lib.getExe pkgs.wazuh-mcp-server;
      };

      devShells.${system}.default = pkgs.mkShell {
        packages = [
          pkgs.actionlint
          pkgs.jq
          pkgs.nixfmt
          pkgs.shellcheck
        ];
      };

      formatter.${system} = pkgs.nixfmt;
    };
}
