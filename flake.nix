{
  inputs = {
    # The host NixOS repo. git+file only sees committed files. After a host
    # sandbox change, run `nix flake update nixos` here.
    nixos.url = "git+file:///home/neal/Documents/nixos";
    # Same nixpkgs as the host sandbox, so store paths are shared.
    nixpkgs.follows = "nixos/nixpkgs";
  };

  outputs =
    { nixos, nixpkgs, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfree = true;
      };

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
      devShells.${system}.default = pkgs.mkShell {
        packages = [ claude ] ++ packages;
      };
    };
}
