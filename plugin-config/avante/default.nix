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
      };

      completion = {
        enable = true;
        trigger_characters = ["." ":" "_"];
        max_lines = 5;
        debounce_ms = 300;
        auto_trigger = true;
        context_lines = 10;
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
        };
      };

      ui = {
        border = "rounded";
        width = 0.8;
        height = 0.8;
        position = "50%";
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
          "AvanteEdit"
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
