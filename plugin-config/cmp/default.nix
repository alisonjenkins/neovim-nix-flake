{
  cmp = {
    enable = true;
    autoEnableSources = true;

    settings = {
      mapping = {
        "<C-d>" = "cmp.mapping.scroll_docs(-4)";
        "<C-e>" = "cmp.mapping.abort()";
        "<C-f>" = "cmp.mapping.scroll_docs(4)";
        "<C-n>" = "cmp.mapping.select_next_item { behavior = cmp.SelectBehavior.Insert }";
        "<C-u>" = "cmp.mapping.complete({})";
        "<C-p>" = "cmp.mapping.select_prev_item { behavior = cmp.SelectBehavior.Insert }";
        "<C-y>" = ''
          cmp.mapping.confirm({ select = true, behavior = cmp.ConfirmBehavior.Insert }, {"i", "c"})'';
        "<C-space>" = ''
          cmp.mapping {
            i = cmp.mapping.complete(),
            c = function(
              _ --[[fallback]]
              )
              if cmp.visible() then
              if not cmp.confirm { select = true } then
              return
              end
              else
              cmp.complete()
              end
              end,
            }
        '';
        "<tab>" = "cmp.config.disable";
      };

      snippet = {
        expand = ''
          function(args)
          require("luasnip").lsp_expand(args.body)
          end
        '';
      };

      sources = [
        { name = "nvim_lsp"; }
        {
          name = "luasnip";
          option = { show_autosnippets = true; };
        }
        { name = "path"; }
        { name = "buffer"; }
      ];
    };
  };
}
