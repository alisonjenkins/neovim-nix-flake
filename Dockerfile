FROM nixos/nix
RUN nix run --extra-experimental-features 'nix-command flakes' 'github:alisonjenkins/neovim-nix-flake'
