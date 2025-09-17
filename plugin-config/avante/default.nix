{
  ...
}: {
  avante = {
    enable = true;

    settings = {
      provider = "gemini";

      behaviour = {
        use_absolute_path = true;
        auto_focus_input = true;
        auto_scroll = true;
        show_line_numbers = true;
        code_action_on_save = true;
        auto_save_history = true;
      };

      completion = {
        enable = true;
        trigger_characters = ["." ":" "_"];
        max_lines = 5;
        debounce_ms = 300;
        auto_trigger = true;
        context_lines = 10;
        inline = {
          enable = true;
          debounce_ms = 300;
          auto_trigger = true;
        };
      };

      providers = {
        gemini = {
          api_key_name = [
            "op" "item" "get" "\"Gemini API Key\"" "--fields" "label=password" "--reveal" "--cache"
          ];
          model = "gemini-1.5-pro";
          temperature = 0.2;
          top_p = 0.95;
          top_k = 40;
          cache_enabled = true;
        };
      };

      ui = {
        border = "rounded";
        width = 0.8;
        height = 0.8;
        position = "50%";
        highlight = true;
        syntax_highlighting = true;
        code_block_background = true;
        markdown = {
          code_block_background = true;
          enable = true;
        };
        input = {
          border = "rounded";
          highlight = true;
        };
      };
    };

    lazyLoad = {
      settings = {
        cmd = [
          "AvanteAsk"
          "AvanteBuild"
          "AvanteChat"
          "AvanteChatNew"
          "AvanteClear"
          "AvanteDocumentation"
          "AvanteEdit"
          "AvanteExplain"
          "AvanteFocus"
          "AvanteHistory"
          "AvanteModels"
          "AvanteRefresh"
          "AvanteShowRepoMap"
          "AvanteStop"
          "AvanteSwitchProvider"
          "AvanteSwitchSelectorProvider"
          "AvanteToggle"
          "AvanteToggleCompletion"
          "AvanteToggleInlineCompletion"
        ];
      };
    };
  };
}
