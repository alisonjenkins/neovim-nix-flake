{
  description = "Test Python project";

  inputs = {
    flake-parts.url = "github:hercules-ci/flake-parts";
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";

    pyproject-nix = {
      url = "github:nix-community/pyproject.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {flake-parts, ...} @ inputs:
    flake-parts.lib.mkFlake {inherit inputs;} {
      systems = let
      in [
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
        pythonTestLintPkgs = python-pkgs: [
          python-pkgs.black # Linter
          python-pkgs.nox # Test + Linter runner
          python-pkgs.pytest # Testing
        ];

        devShell = pkgs.mkShell {
          packages = with pkgs; [
            alejandra
            pythonTestEnv
            watchexec
            just
          ];
        };

        example-python-project = inputs.pyproject-nix.lib.project.loadPyproject {
          # Read & unmarshal pyproject.toml relative to this project root.
          # projectRoot is also used to set `src` for renderers such as buildPythonPackage.
          projectRoot = ./.;
        };

        arg = example-python-project.renderers.withPackages {
          inherit python;
        };
        testing-arg = example-python-project.renderers.withPackages {
          inherit python;
          extraPackages = pythonTestLintPkgs;
        };

        pythonEnv = python.withPackages arg;
        pythonTestEnv = python.withPackages testing-arg;
        python = pkgs.python3;

        alejandra-check =
          pkgs.runCommandLocal "alejandra-check" {
            src = ./.;

            nativeBuildInputs = [
              pkgs.alejandra
            ];
          } ''
            cd "$src" && alejandra --check .
            mkdir "$out"
          '';

        nox-check =
          pkgs.runCommandLocal "nox-check" {
            src = ./.;

            nativeBuildInputs = [
              # (
              #   pkgs.python3.withPackages (python-pkgs: pythonTestLintPkgs python-pkgs)
              # )
              # (
              #   pythonEnv.withPackages (python-pkgs: pythonTestLintPkgs python-pkgs)
              # )
              pythonTestEnv
            ];
          } ''
            cd "$src" && nox
            mkdir "$out"
          '';
      in {
        checks = {
          inherit alejandra-check;
          inherit nox-check;
        };
        devShells.default = devShell;
        packages.default = let
          attrs = example-python-project.renderers.buildPythonPackage {inherit python;};
        in
          python.pkgs.buildPythonPackage (attrs
            // {
              # env.CUSTOM_ENVVAR = "hello";
            });
      };
    };
}
