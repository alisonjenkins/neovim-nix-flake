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

      bufdelete = {
        enabled = true;
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
