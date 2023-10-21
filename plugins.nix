{ pkgs }:
with pkgs.vimPlugins; [
  telescope-nvim
  telescope-recent-files
  nvim-lspconfig
]
