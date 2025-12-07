{ pkgs, ... }:
let
  enable = false;
in
{
  neotest = {
    enable = enable;

    adapters = {
      bash.enable = enable;
      go.enable = enable;
      java.enable = enable;
      plenary.enable = enable;
      python.enable = enable;
      rust.enable = enable;
      zig.enable = enable;
    };

    settings = {
      log_level = "warn";

      discovery = { enabled = true; };

      output_panel = { enabled = true; };
    };

    # lazyLoad = {
    #   settings = {
    #     cmd = [
    #       "Neotest"
    #       "NeotestJava"
    #     ];
    #   };
    # };
  };
}
