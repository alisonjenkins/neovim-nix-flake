{pkgs, ...}: {
  lsp = {
    enable = true;
    inlayHints = true;

    servers = {
      # java_language_server.enable = false;
      # jdtls.enable = false;
      # pylyzer.enable = false;
      # ruff_lsp.enable = false;
      # vectorcode_server.enable = true;
      # zls.enable = false;
      asm_lsp.enable = true;
      bashls.enable = true;
      bashls.package = pkgs.master.bash-language-server;
      copilot.enable = true;
      cssls.enable = true;
      dockerls.enable = true;
      earthlyls.enable = true;
      emmet_ls.enable = true;
      fortls.enable = true;
      golangci_lint_ls.enable = true;
      gopls.enable = true;
      html.enable = true;
      jsonls.enable = true;
      lua_ls.enable = true;
      nushell.enable = true;
      pylsp.enable = true;
      qmlls.enable = true;
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

      ccls = {
        enable = true;
        package = pkgs.stable.ccls;
      };

      helm_ls = {
        enable = true;
        filetypes = [ "helm" ];
      };

      marksman = {
        enable = true;
        package = pkgs.stable.marksman;
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
