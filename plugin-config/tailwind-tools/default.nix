{
  tailwind-tools = {
    enable = true;

    settings = {
      server = {
        override = true;
      };
      document_color = {
        enabled = true;
        kind = "inline";
        inline_symbol = "󰝤 ";
        debounce = 200;
      };
      conceal = {
        enabled = true;
        min_length = null;
        symbol = "󱏿";
        highlight = {
          fg = "#38BDF8";
        };
      };
      cmp = {
        highlight = "foreground";
      };
    };
  };
}
