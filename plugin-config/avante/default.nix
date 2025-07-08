{
  ...
}: {
  avante = {
    enable = false;

    settings = {
      provider = "gemini";

      behaviour = {
        use_absolute_path = true;
      };

      providers = {
        gemini = {
          api_key_name = [
            "op" "item" "get" "Gemini API Key" "--fields" "label=password" "--reveal" "--cache"
          ];
        };
      };
    };
  };
}
