{
  dap-ui = {
    enable = true;

    lazyLoad.settings = {
      cmd = [ "DapContinue" "DapToggleBreakpoint" "DapStepOver" "DapStepInto" "DapStepOut" ];
      keys = [
        "<leader>db"  # Debug breakpoint
        "<leader>dc"  # Debug continue
        "<leader>ds"  # Debug step
        "<leader>du"  # Debug UI
      ];
    };
  };
}
