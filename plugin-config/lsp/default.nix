{pkgs, ...}: {
  lsp = {
    enable = true;
    inlayHints = true;

    servers = {
      # vectorcode_server.enable = true;
      asm_lsp.enable = true;
      bashls.enable = true;
      bashls.package = pkgs.master.bash-language-server;
      ccls.enable = true;
      copilot.enable = true;
      cssls.enable = true;
      dockerls.enable = true;
      earthlyls.enable = true;
      emmet_ls.enable = true;
      fortls.enable = true;
      golangci_lint_ls.enable = true;
      gopls.enable = true;
      html.enable = true;
      java_language_server.enable = false;
      jdtls.enable = false;
      jsonls.enable = true;
      lua_ls.enable = true;
      marksman.enable = true;
      nushell.enable = true;
      pylsp.enable = true;
      pylyzer.enable = false;
      qmlls.enable = true;
      ruff_lsp.enable = false;
      superhtml.enable = true;
      systemd_ls.enable = true;
      tailwindcss.enable = true;
      taplo.enable = true;
      terraformls.enable = true;
      tflint.enable = true;
      tilt_ls.enable = true;
      ts_ls.enable = true;
      vacuum.enable = true;
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
