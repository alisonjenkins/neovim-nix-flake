{
  ...
}: {
  avante = {
    enable = true;

    settings = {
      provider = "gemini";
      gemini = {
        api_key_name = [
          "op" "item" "get" "Gemini API Key" "--fields" "label=password" "--reveal"
        ];
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
