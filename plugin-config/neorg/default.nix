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
            workspaces = {
              home = "~/git/todo/home";
              work = "~/git/todo/work";
            };
          };
        };
      };
    };
  };
}
