{
  crates-nvim = {
    enable = true;

    extraOptions = {
      lsp = {
        actions = true;
        completion = true;
        enabled = true;
        hover = true;
      };
    };
  };
}
