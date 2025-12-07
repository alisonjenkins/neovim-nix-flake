{ pkgs, ... }: {
  noice = {
    enable = true;
    package = pkgs.master.vimPlugins.noice-nvim;
  };
}
