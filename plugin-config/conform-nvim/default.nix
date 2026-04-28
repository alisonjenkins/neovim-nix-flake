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
        # NOTE: terraform deliberately NOT listed here. We want conform
        # to fall through to the LSP (`tfls`) so the runtime-toggleable
        # formatStyle (minimal vs opinionated) takes effect. Listing
        # `terraform_fmt` would shell out to the terraform CLI and
        # bypass tfls entirely — block reorders / hoisting would then
        # never appear. `lsp_fallback = true` on every conform call
        # site (already set) routes terraform through tfls.
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
        return { timeout_ms = 1000, lsp_fallback = true }
        end
      '';
    };
  };
}
