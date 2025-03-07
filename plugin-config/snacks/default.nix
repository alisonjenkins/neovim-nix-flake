{
  snacks = {
    enable = true;

    settings = {
      animate = {
        enabled = true;
      };

      bigfile = {
        enabled = true;
      };

      bufdelete = { };

      dashboard = {
        enabled = true;

        formats.__raw = ''
          {
            key = function(item)
              return { { "[", hl = "special" }, { item.key, hl = "key" }, { "]", hl = "special" } }
            end,
          }
        '';

        sections.__raw = ''
          {
            { section = "header" },
            {
              pane = 1,
              section = "terminal",
              cmd = "colorscript -e square",
              padding = 1,
            },
            { section = "keys", gap = 1, padding = 1 },
            { pane = 2, icon = " ", title = "Recent Files", section = "recent_files", indent = 2, padding = 1 },
            { pane = 2, icon = " ", title = "Projects", section = "projects", indent = 2, padding = 1 },
            {
              pane = 2,
              height = 16,
              section = "terminal",
              cmd = "fortune -s | cowsay",
              padding = 1,
            },
          },
        '';
      };

      gitbrowse = {
        enabled = true;
      };

      image = {
        enabled = true;
      };

      indent = {
        enabled = true;
      };

      quickfile = {
        enabled = true;
      };

      scroll = {
        enabled = true;
      };

      notifier = {
        enabled = true;
        timeout = 3000;
      };

      statuscolumn = {
        enabled = true;
      };

      picker = {
        matcher = {
          frecency = true;
          sort_empty = true;
        };

        formatters = {
          file = {
            truncate = 200;
          };
        };

        layout = {
          __raw = ''
            {
              layout = {
                box = "vertical",
                backdrop = false,
                row = -1,
                width = 0,
                height = 0,
                border = "top",
                title = " {title} {live} {flags}",
                title_pos = "left",
                { win = "input", height = 1, border = "bottom" },
                {
                  box = "horizontal",
                  { win = "list", border = "none", height = 0 },
                  { win = "preview", title = "{preview}", width = 0.3, height = 0, border = "left" },
                },
              },
            }
          '';
        };
      };
    };
  };
}
