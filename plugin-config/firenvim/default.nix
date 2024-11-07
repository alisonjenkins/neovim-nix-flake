{
  firenvim = {
    enable = true;

    settings = {
      globalSettings.alt = "all";

      localSettings = {
        ".*" = {
          cmdline = "firenvim";
          content = "text";
          priority = 0;
          selector = "textarea";
          takeover = "never";
        };
      };
    };
  };
}
