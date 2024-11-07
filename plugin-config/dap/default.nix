{
  dap = {
    enable = true;

    extensions = {
      dap-python.enable = true;
      dap-ui.enable = true;
      dap-virtual-text.enable = true;

      dap-go = {
        enable = true;

        delve.path = "${pkgs.delve}/bin/dlv";
      };
    };
  };
}
