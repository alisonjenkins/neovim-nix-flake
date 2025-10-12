{
  tailwind-tools = {
    enable = true;

    settings = {
      cmp = {
        highlight = "foreground";
      };

      conceal = {
        enabled = true;
        min_length = null;
        symbol = "󱏿";
        highlight = {
          fg = "#38BDF8";
        };
      };

      document_color = {
        enabled = true;
        kind = "inline";
        inline_symbol = "󰝤 ";
        debounce = 200;
      };

      server = {
        override = true;
      };
    };
  };
}
