{ pkgs, ... }: {
  noice = {
    enable = true;
    package = pkgs.master.vimPlugins.noice-nvim;

    settings.lsp = {
      # Let fidget.nvim handle LSP progress display; noice's progress handler
      # overrides vim.lsp.handlers["$/progress"] and prevents LspProgress
      # autocmd from firing, which makes fidget invisible.
      progress.enabled = false;

      override = {
        "vim.lsp.util.convert_input_to_markdown_lines" = true;
        "vim.lsp.util.stylize_markdown" = true;
      };
    };
  };
}
