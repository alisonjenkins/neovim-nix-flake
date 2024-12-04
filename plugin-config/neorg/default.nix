{ ... }: {
  neorg = {
    enable = true;

    modules = {
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
}
