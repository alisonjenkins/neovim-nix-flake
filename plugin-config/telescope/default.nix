{
  telescope = {
    enable = true;

    lazyLoad.settings = {
      cmd = [ "Telescope" ];
    };

    extensions = {
      file-browser.enable = true;
      fzy-native.enable = true;
      ui-select.enable = true;

      frecency = {
        enable = true;

        settings = { db_safe_mode = false; };
      };
    };
  };
}
