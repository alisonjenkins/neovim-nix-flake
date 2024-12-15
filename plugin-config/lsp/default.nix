{
  lsp = {
    enable = true;
    inlayHints = true;

    servers = {
      ansiblels.enable = true;
      bashls.enable = true;
      ccls.enable = true;
      cssls.enable = true;
      dockerls.enable = true;
      emmet_ls.enable = true;
      golangci_lint_ls.enable = true;
      gopls.enable = true;
      html.enable = true;
      java_language_server.enable = false;
      jdtls.enable = false;
      jsonls.enable = true;
      lua_ls.enable = true;
      nushell.enable = true;
      pylsp.enable = true;
      pylyzer.enable = false;
      ruff_lsp.enable = false;
      superhtml.enable = true;
      tailwindcss.enable = true;
      terraformls.enable = true;
      ts_ls.enable = true;
      veryl_ls.enable = true;
      zls.enable = false;

      helm_ls = {
        enable = true;
        filetypes = [ "helm" ];
      };

      nixd = {
        enable = true;

        settings = {
          formatting.command = [ "nixpkgs-fmt" ];
          nixpkgs.expr = "import <nixpkgs> {}";
        };
      };

      yamlls = {
        enable = true;
        filetypes = [ "yaml" ];
      };
    };
  };
}
