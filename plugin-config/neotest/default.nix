{
  neotest = {
    enable = true;

    # Not on :Neotest: neotest is a dependency of the adapter plugins, so its plugin/ files
    # define :Neotest at startup and the lazy-load command stub never runs setup().
    lazyLoad.settings.event = [ "User DeferredStage3" ];

    adapters = {
      bash.enable = true;
      go.enable = true;
      java.enable = true;
      plenary.enable = true;
      python.enable = true;
      rust.enable = true;
      zig.enable = true;
    };

    settings = {
      log_level = "warn";
      discovery = { enabled = true; };
      output_panel = { enabled = true; };
    };

  };
}
