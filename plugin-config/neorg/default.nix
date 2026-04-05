{ ... }: {
  neorg = {
    enable = true;

    lazyLoad.settings = {
      ft = [ "norg" ];
      cmd = [ "Neorg" ];
    };

    settings = {
      load = {
        "core.defaults" = {
          __empty = null;
        };
        "core.dirman" = {
          config = {
            workspaces.__raw = ''
              {
                home = vim.fn.getenv("NEORG_HOME_DIR") ~= vim.NIL and vim.fn.getenv("NEORG_HOME_DIR") or "~/git/todo/home",
                work = vim.fn.getenv("NEORG_WORK_DIR") ~= vim.NIL and vim.fn.getenv("NEORG_WORK_DIR") or "~/git/todo/work",
              }
            '';
          };
        };
      };
    };
  };
}
