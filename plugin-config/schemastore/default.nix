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

    # yaml.schemas is now resolved per-buffer via yamlls's
    # custom/schema/request flow (see modules/plugins/schema-companion.nix).
    # The schemastore.nvim catalog conflicts with that flow because its huge
    # yaml.schemas list short-circuits resolveSchema before customSchemaProvider
    # in some cases and blocks dynamic CRD detection.
    yaml = {
      enable = false;
    };
  };
}
