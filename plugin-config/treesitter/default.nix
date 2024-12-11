{ pkgs, ... }:
{
  treesitter =
    {
      enable = true;

      grammarPackages = pkgs.vimPlugins.nvim-treesitter.passthru.allGrammars;

      settings = {
        textobjects.enable = true;

        highlight = {
          enable = true;

          disable = ''
            function(lang, bufnr)
            return vim.api.nvim_buf_line_count(bufnr) > 10000
            end
          '';
        };

        incremental_selection = { enable = true; };

        indent = { enable = false; };
      };
    };
}
