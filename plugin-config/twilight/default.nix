{
  twilight = {
    enable = true;

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

    lazyLoad = {
      settings = {
        cmd = [
          "Twilight"
          "TwilightEnable"
          "TwilightDisable"
        ];
      };
    };
  };
}
