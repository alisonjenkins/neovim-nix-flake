{
  luasnip = {
    enable = true;

    # Optimize snippet loading - only load specific snippet packs you need
    fromVscode = [
      {
        # Only load essential snippet collections
        include = [
          "css"
          "go"
          "html"
          "javascript"
          "lua"
          "markdown"
          "nix"
          "python"
          "rust"
          "terraform"
          "typescript"
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
      enable_autosnippets = false; # Disable if you don't use them
    };
  };
}
