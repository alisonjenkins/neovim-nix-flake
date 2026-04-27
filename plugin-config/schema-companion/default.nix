{
  schema-companion = {
    enable = true;

    settings = {
      log_level.__raw = "vim.log.levels.WARN";
    };

    adapters = {
      yamlls = {
        sources = [
          { type = "matcher"; name = "kubernetes"; settings = { version = "master"; }; }
          { type = "lsp"; }
          {
            type = "schemas";
            schemas = [
              {
                name = "Kubernetes (master)";
                uri = "https://raw.githubusercontent.com/yannh/kubernetes-json-schema/master/master-standalone-strict/all.json";
              }
            ];
          }
        ];
      };

      helmls = {
        server = "helm_ls";
        sources = [
          { type = "matcher"; name = "kubernetes"; settings = { version = "master"; }; }
        ];
      };
    };
  };
}
