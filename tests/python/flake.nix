{
  description = "Test Python project";

  inputs = {
    flake-parts.url = "github:hercules-ci/flake-parts";
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
  };

  outputs = {flake-parts, ...}@inputs: 
    flake-parts.lib.mkFlake {inherit inputs;} {
      systems = [
        "aarch64-darwin"
        "aarch64-linux"
        "x86_64-darwin"
        "x86_64-linux"
      ];

      perSystem = {
        pkgs,
        system,
        ...
      }: let 
        devShell = pkgs.mkShell {
          packages = [
            (
              pkgs.python3.withPackages (python-pkgs: [
                python-pkgs.pytest
              ])
            )
          ];
        };
      in {
        devShells.default = devShell;
      };
  };
}
