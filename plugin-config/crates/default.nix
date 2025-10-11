{
  crates = {
    enable = true;

    settings = {
      autoload = true;
      autoupdate = true;
      smart_insert = true;
      thousands_separator = ",";

      lsp = {
        enabled = true;
        actions = true;
        completion = true;
        hover = true;
      };
    };

    lazyLoad = {
      enable = true;
      settings = {
        event = [
          "BufRead Cargo.toml"
        ];
      };
    };
  };
}
