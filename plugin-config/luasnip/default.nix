{
  luasnip = {
    enable = true;

    # Optimize snippet loading - only load specific snippet packs you need
    fromVscode = [
      {
        # Only load essential snippet collections
        include = [
          "javascript"
          "typescript"
          "python"
          "go"
          "rust"
          "lua"
          "nix"
          "markdown"
          "html"
          "css"
        ];
      }
    ];

    lazyLoad.settings = {
      event = [ "InsertEnter" ];
    };

    settings = {
      # Performance optimizations
      update_events = [ "TextChanged" "TextChangedI" ];
      delete_check_events = [ "TextChanged" ];
      enable_autosnippets = false;  # Disable if you don't use them
    };
  };
}
