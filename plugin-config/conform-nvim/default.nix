{
  conform-nvim = {
    enable = true;

    settings = {
      formatters_by_ft = {
        "_" = [ "trim_whitespace" ];
        go = [ "goimports" "golines" "gofmt" "gofumpt" ];
        javascript.__raw = ''
          {
            "prettierd",
            "prettier",
            stop_after_first = true
          }'';
        json = [ "jq" ];
        lua = [ "stylua" ];
        python = [ "isort" "black" ];
        rust = [ "rustfmt" ];
        sh = [ "shfmt" ];
        # Force a literal empty Lua table via `__raw`. Plain
        # `terraform = [ ];` would be optimised away by nixvim's
        # code-gen (empty lists collapse to nothing in the
        # generated init.lua), and we'd be back to the `_`
        # fallback (`trim_whitespace`) catching terraform and
        # conform never hitting its LSP-fallback branch.
        # An explicit empty table tells conform "no formatters
        # for terraform" — combined with `lsp_format = "fallback"`
        # on every call site, that routes formatting requests to
        # tfls and honours the runtime-toggleable formatStyle.
        terraform.__raw = "{}";
      };

      format_on_save = ''
        function(bufnr)
        local ignore_filetypes = { "helm" }
        if vim.tbl_contains(ignore_filetypes, vim.bo[bufnr].filetype) then
        return
        end

        -- Disable with a global or buffer-local variable
        if vim.g.disable_autoformat or vim.b[bufnr].disable_autoformat then
        return
        end

        -- Disable autoformat for files in a certain path
        local bufname = vim.api.nvim_buf_get_name(bufnr)
        if bufname:match("/node_modules/") then
        return
        end
        return { timeout_ms = 1000, lsp_format = "fallback" }
        end
      '';
    };
  };
}
