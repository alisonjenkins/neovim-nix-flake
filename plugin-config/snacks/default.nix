{
  snacks = {
    enable = true;

    settings = {
      animate = {
        enabled = true;
      };

      bigfile = {
        enabled = true;
        size = 1048576; # 1MB
        setup.__raw = ''
          function(ctx)
            vim.cmd([[NoMatchParen]])
            -- Disable snacks word highlighting
            require("snacks").words.enabled = false
            -- Disable mini.hipatterns pattern scanning
            vim.b[ctx.buf].minihipatterns_disable = true
            -- Disable snacks indent guides
            vim.b[ctx.buf].snacks_indent = false
            -- Disable snacks scope highlighting
            vim.b[ctx.buf].snacks_scope = false
            -- Disable snacks smooth scrolling (very expensive on huge buffers)
            vim.b[ctx.buf].snacks_scroll = false
            -- Also covers long-line files under 1 MB, which only snacks detects
            vim.b[ctx.buf].bigfile = true
            -- conform: skip format-on-save (trim_whitespace copies every line)
            vim.b[ctx.buf].disable_autoformat = true
            -- smear-cursor animates every cursor jump and redraws on each move: switch it
            -- off while a big buffer is current and put its previous state back after
            -- (it may have been toggled off already).
            local smear_was_enabled
            local function smear(in_big_buffer)
              local ok, s = pcall(require, "smear_cursor")
              if not ok then return end
              if in_big_buffer then
                if smear_was_enabled == nil then smear_was_enabled = s.enabled end
                if s.enabled then s.enabled = false end
              elseif smear_was_enabled ~= nil then
                s.enabled = smear_was_enabled
                smear_was_enabled = nil
              end
            end
            vim.api.nvim_create_autocmd({ "BufEnter", "BufLeave", "BufWipeout" }, {
              buffer = ctx.buf,
              callback = function(ev) smear(ev.event == "BufEnter") end,
            })
            if vim.api.nvim_get_current_buf() == ctx.buf then smear(true) end
            -- Hook FileType so we clear syntax/rendering AFTER filetype scripts run,
            -- not via vim.schedule which races against those scripts
            vim.api.nvim_create_autocmd("FileType", {
              buffer = ctx.buf,
              once = true,
              callback = function()
                if not vim.api.nvim_buf_is_valid(ctx.buf) then return end
                vim.bo[ctx.buf].syntax = ""
                pcall(vim.treesitter.stop, ctx.buf)
                vim.opt_local.relativenumber = false
                vim.opt_local.cursorline = false
                vim.opt_local.foldcolumn = "0"
                vim.opt_local.foldmethod = "manual"
                if package.loaded["mini.indentscope"] then
                  vim.b[ctx.buf].miniindentscope_disable = true
                end
              end,
            })
          end
        '';
      };

      bufdelete = { };

      dashboard = {
        enabled = false;

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
        enabled = false;
      };

      indent = {
        enabled = true;
      };

      input = {
        enabled = true;
      };

      quickfile = {
        enabled = true;
      };

      scope = {
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
        enabled = false;
      };

      picker = {
        matcher = {
          cwd_bonus = true;
          frecency = true;
          history_bonus = true;
          sort_empty = true;
        };

        formatters = {
          file = {
            truncate = 200;
          };
        };

        win.__raw = ''
          {
            position = "float",
            relative = "editor",
          }
        '';

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
