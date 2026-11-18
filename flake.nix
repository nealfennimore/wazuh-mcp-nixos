{
  description = "Nix package and NixOS module for Wazuh MCP Server";

  inputs = {
    # The host NixOS repo. git+file only sees committed files. After a host
    # sandbox change, run `nix flake update nixos` here.
    nixos.url = "git+file:///home/neal/Documents/nixos";
    # Same nixpkgs as the host sandbox, so store paths are shared.
    nixpkgs.follows = "nixos/nixpkgs";
  };

  outputs =
    { self, nixos, nixpkgs, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfree = true;
        overlays = [ self.overlays.default ];
      };
      inherit (pkgs) lib;

      # Project tools: on the shell PATH and inside the sandbox.
      packages = [
      ];

      projectSandbox = {
        extraPackages = packages;
        allowedDomains = {
          "crates.io" = "*";
        };
        extraEnv = {
        };
      };

      # Module merge onto the host sandbox: lists append, attrsets merge.
      # To replace a host value, wrap it in nixpkgs.lib.mkForce.
      claude = nixos.packages.${system}.claude.extend projectSandbox;
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

        # Lint the GitHub Actions workflows and the update and CI scripts.
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
                  ./ci
                  ./nix/update.sh
                ];
              };
            }
            ''
              cd $src
              actionlint -shellcheck=${lib.getExe pkgs.shellcheck} .github/workflows/*.yml
              shellcheck nix/update.sh ci/flake-args ci/nix-build
              touch $out
            '';
      };

      apps.${system}.default = {
        type = "app";
        program = lib.getExe pkgs.wazuh-mcp-server;
      };

      devShells.${system}.default = pkgs.mkShell {
        packages = [ claude ] ++ packages;
      };

      formatter.${system} = pkgs.nixfmt;
    };
}
