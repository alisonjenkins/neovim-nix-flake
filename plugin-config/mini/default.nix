{
  mini = {
    enable = true;

    modules = {
      ai = {
        n_lines = 400;
        search_method = "cover_or_next";
      };

      bufremove = { };

      hipatterns = {
        highlighters = {
          # *FIXME*
          fixme = {
            pattern = "%f[%w]()FIXME()%f[%W]";
            group = "MiniHipatternsFixme";
          };
          # *HACK*
          hack = {
            pattern = "%f[%w]()HACK()%f[%W]";
            group = "MiniHipatternsHack";
          };
          # *TODO*
          todo = {
            pattern = "%f[%w]()TODO()%f[%W]";
            group = "MiniHipatternsTodo";
          };
          # *NOTE*
          note = {
            pattern = "%f[%w]()NOTE()%f[%W]";
            group = "MiniHipatternsNote";
          };

          # Highlight hex color strings (`#rrggbb`) using that color
          hex_color = "hipatterns.gen_highlighter.hex_color()";
        };
      };

      starter = {
        query_updaters = "abcdefghijklmnopqrstuvwxyz0123456789_.";
        header.__raw = ''
          function()
            local hour = tonumber(os.date("%H"))
            local greeting
            if hour < 6 then greeting = "Good night"
            elseif hour < 12 then greeting = "Good morning"
            elseif hour < 18 then greeting = "Good afternoon"
            else greeting = "Good evening"
            end
            local header = greeting .. ", " .. (vim.env.USER or "user") .. "\n\n"
            -- fortune/cowsay is computed asynchronously in extraConfigLua to avoid
            -- blocking the dashboard on AV binary scans; result arrives via refresh()
            if vim.g._fortune_result then
              header = header .. vim.g._fortune_result
            end
            return header
          end
        '';
        items.__raw = ''
          {
            require('mini.starter').sections.recent_files(5, false),
            require('mini.starter').sections.recent_files(5, true),
            require('mini.starter').sections.builtin_actions(),
          }
        '';
        footer = "";
      };

      surround = {
        mappings = {
          add = "gsa";
          delete = "gsd";
          find = "gsf";
          find_left = "gsF";
          highlight = "gsh";
          replace = "gsr";
          update_n_lines = "gsn";
        };
      };
    };
  };
}
