{
  ...
}: {
  avante = {
    enable = true;

    settings = {
      provider = "copilot";

      behaviour = {
        use_absolute_path = true;
      };

      providers = {
        gemini = {
          api_key_name = [
            "op" "item" "get" "Gemini API Key" "--fields" "label=password" "--reveal"
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
          "AvanteHistory"
          "AvanteClear"
          "AvanteEdit"
          "AvanteFocus"
          "AvanteRefresh"
          "AvanteStop"
          "AvanteSwitchProvider"
          "AvanteShowRepoMap"
          "AvanteToggle"
          "AvanteModels"
          "AvanteSwitchSelectorProvider"
        ];
      };
    };
  };
}
