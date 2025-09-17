{
  ...
}: {
  avante = {
    enable = true;

    settings = {
      provider = "gemini";

      behaviour = {
        use_absolute_path = true;
      };

      completion = {
        enable = true;
        trigger_characters = ["."];
        max_lines = 5;
        debounce_ms = 300;
      };

      providers = {
        gemini = {
          api_key_name = [
            "op" "item" "get" "\"Gemini API Key\"" "--fields" "label=password" "--reveal" "--cache"
          ];
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
        ];
      };
    };
  };
}
