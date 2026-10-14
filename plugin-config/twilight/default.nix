{
  twilight = {
    enable = true;

    lazyLoad.settings.event = [ "DeferredUIEnter" ];

    settings = {
      context = 20;
      treesitter = true;

      dimming = {
        alpha = 0.4;
      };

      expand = [
        "function"
        "if_statement"
        "method"
        "table"
      ];
    };
  };
}
