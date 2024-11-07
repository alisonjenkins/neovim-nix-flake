{
  neotest = {
    enable = true;

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
