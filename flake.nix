{
  description = "Alison Jenkins - Neovim Flake";
  inputs = {
    flake-utils = {
      url = "github:numtide/flake-utils";
    };
    nixpkgs = {
      url = "github:NixOS/nixpkgs";
    };
    neovim = {
      url = "github:neovim/neovim/stable?dir=contrib";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    telescope-recent-files-src = {
      url = "github:smartpde/telescope-recent-files";
      flake = false;
    };
  };
  outputs = { self, flake-utils, nixpkgs, neovim, telescope-recent-files-src }:
  flake-utils.lib.eachDefaultSystem
    (system:
      let
        overlayFlakeInputs = prev: final: {
          neovim = neovim.packages.${system}.neovim;

          vimPlugins = final.vimPlugins // {
            telescope-recent-files = import ./packages/vimPlugins/telescopeRecentFiles.nix {
              src = telescope-recent-files-src;
              pkgs = prev;
            };
          };
        };

        overlayMyNeovim = prev: final: {
          myNeovim = import ./packages/myNeovim.nix {
            pkgs = final;
          };
        };

        pkgs = import nixpkgs {
          inherit system;
          overlays = [ overlayFlakeInputs overlayMyNeovim ];
        };
      in
      {
        packages.${system}.default = pkgs.myNeovim;
        apps.${system}.default = {
          type = "app";
          program = "${pkgs.myNeovim}/bin/nvim";
        };
      }
    );
}
