{ pkgs, ... }: {
  dap = {
    enable = true;

    lazyLoad = {
      settings = {
        keys = [
          "<leader>d"
        ];
      };
    };
  };
}
