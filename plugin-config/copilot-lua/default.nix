{
  copilot-lua = {
    enable = true;

    lazyLoad.settings = {
      event = [ "InsertEnter" ];
    };

    settings = {
      panel.enabled = false;
      suggestion.enabled = false;

      filetypes = {
        help = true;
        markdown = true;
      };
    };
  };
}
