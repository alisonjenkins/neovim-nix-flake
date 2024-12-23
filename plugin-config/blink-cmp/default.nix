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
        ];

        providers = {
          lsp = {
            name = "LSP";
            module = "blink.cmp.sources.lsp";
            fallbacks = [
              "buffer"
            ];
            # transform_items = ''
            #   function(_, items)
            #     for _, item in ipairs(items) do
            #       if item.kind == require('blink.cmp.types').CompletionItemKind.Snippet then
            #         item.score_offset = item.score_offset - 3
            #       end
            #     end
            #     return vim.tbl_filter(
            #       function(item) return item.kind ~= require('blink.cmp.types').CompletionItemKind.Text end,
            #       items
            #     )
            #   end
            # '';

            enabled = true;
            async = false;
            timeout_ms = 2000;
            should_show_items = true;
            max_items = null;
            min_keyword_length = 0;
            score_offset = 0;
            override = null;
          };
          path = {
            name = "Path";
            module = "blink.cmp.sources.path";
            score_offset = 3;
            fallbacks = [
              "buffer"
            ];
            opts = {
              trailing_slash = false;
              label_trailing_slash = true;
              # get_cwd = ''
              #   function(context) return vim.fn.expand(('#%d:p:h'):format(context.bufnr)) end
              # '';
              show_hidden_files_by_default = false;
            };
          };
          snippets = {
            name = "Snippets";
            module = "blink.cmp.sources.snippets";
            opts = {
              friendly_snippets = true;
              global_snippets = [
                "all"
              ];
              extended_filetypes = [ ];
              ignored_filetypes = [ ];
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
            opts = {
              get_bufnrs = ''
                function()
                  return vim
                    .iter(vim.api.nvim_list_wins()): map (function (win) return vim.api.nvim_win_get_buf (win) end)
                    :filter(function(buf) return vim.bo[buf].buftype ~= 'nofile' end)
                    :totable()
                end
              '';
            };
          };
        };
      };

      signature = {
        enabled = true;
      };
    };
  };
}
