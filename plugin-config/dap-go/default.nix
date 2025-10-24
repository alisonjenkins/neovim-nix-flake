{ pkgs }: {
  dap-go = {
    enable = true;

    settings = {
      delve.path = "${pkgs.delve}/bin/dlv";
    };

    lazyLoad = {
      settings = {
        ft = "go";
      };
    };
  };
}
