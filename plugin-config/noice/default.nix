{ pkgs, ... }: {
  noice = {
    enable = true;
    package = pkgs.master.vimPlugins.noice-nvim;

    settings.lsp.override = {
      "vim.lsp.util.convert_input_to_markdown_lines" = true;
      "vim.lsp.util.stylize_markdown" = true;
    };
  };
}
