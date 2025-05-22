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
  };
}
