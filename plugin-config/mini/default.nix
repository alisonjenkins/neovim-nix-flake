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
