{ pkgs }:
let
  customRC = import ../config { inherit pkgs; };
  plugins = import ../plugins.nix { inherit pkgs; };
  runtimeDeps = import ../runtimeDeps.nix { inherit pkgs; };
  neovimRuntimeDependencies = pkgs.symlinkJoin {
    name = "neovim-runtime-dependencies";
    paths = runtimeDeps.deps1;
  };
  neovimRuntimeDependencies2 = pkgs.symlinkJoin {
    name = "neovim-runtime-dependencies2";
    paths = runtimeDeps.deps2;
  };
  myNeovimUnwrapped = pkgs.wrapNeovim pkgs.neovim {
    configure = {
      inherit customRC;
      packages.all.start = plugins;
    };
  };
in
pkgs.writeShellApplication {
  name = "nvim";
  runtimeInputs = [ neovimRuntimeDependencies neovimRuntimeDependencies2 ];
  text = ''
    ${myNeovimUnwrapped}/bin/nvim "$@"
  '';
}
