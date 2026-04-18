{
  luasnip = {
    enable = true;

    # Load vscode-format snippet packs for most languages, but skip
    # `terraform` — we rely on tfls's own snippet completions there.
    fromVscode = [
      {
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
