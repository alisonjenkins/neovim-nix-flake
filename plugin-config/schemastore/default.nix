{
  schemastore = {
    enable = true;

    json = {
      enable = true;

      settings = {
        extra = [
          {
            description = "Flux2 schemas for when working with Flux Gitops resources.";
            fileMatch = "*.yaml";
            name = "flux2";
            url = "https://raw.githubusercontent.com/fluxcd-community/flux2-schemas/refs/heads/main/all.json";
          }
        ];
      };
    };

    yaml = {
      enable = true;
    };
  };
}
