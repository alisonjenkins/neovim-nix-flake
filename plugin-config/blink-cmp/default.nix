{ ... }: {
  blink-cmp = {
    enable = true;

    settings = {
      completion = {
        accept = {
          auto_brackets = {
            enabled = false;
          };
        };

        documentation = {
          auto_show = true;
          auto_show_delay_ms = 200;
        };

        ghost_text = {
          enabled = true;
        };
      };

      sources = {
        default = [
          "lsp"
          "path"
          "snippets"
          "buffer"
          "copilot"
        ];

        providers = {
          lsp = {
            name = "LSP";
            module = "blink.cmp.sources.lsp";
            async = false;
            enabled = true;
            max_items = null;
            min_keyword_length = 0;
            override = null;
            score_offset = 0;
            should_show_items = true;
            timeout_ms = 2000;

            fallbacks = [
              "buffer"
            ];
          };
          path = {
            name = "Path";
            module = "blink.cmp.sources.path";
            score_offset = 3;

            fallbacks = [
              "buffer"
            ];

            opts = {
              label_trailing_slash = true;
              show_hidden_files_by_default = false;
              trailing_slash = false;
            };
          };
          snippets = {
            name = "Snippets";
            module = "blink.cmp.sources.snippets";

            opts = {
              friendly_snippets = true;
              extended_filetypes = [ ];
              ignored_filetypes = [ ];

              global_snippets = [
                "all"
              ];
            };
          };
          luasnip = {
            name = "Luasnip";
            module = "blink.cmp.sources.luasnip";

            opts = {
              use_show_condition = true;
              show_autosnippets = true;
            };
          };
          buffer = {
            name = "Buffer";
            module = "blink.cmp.sources.buffer";

            # opts = {
            #   get_bufnrs = ''
            #     function()
            #       return vim
            #         .iter(vim.api.nvim_list_wins()): map (function (win) return vim.api.nvim_win_get_buf (win) end)
            #         :filter(function(buf) return vim.bo[buf].buftype ~= 'nofile' end)
            #         :totable()
            #     end
            #   '';
            # };
          };
          copilot = {
            name = "copilot";
            module = "blink-cmp-copilot";
            score_offset = 100;
            async = true;
          };
        };
      };

      signature = {
        enabled = true;
      };
    };
  };
}
