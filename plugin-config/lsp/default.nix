{ pkgs, lspWrappers, terraform-ls-rs, ... }:
let
  lspmuxBin = "${pkgs.lspmux}/bin/lspmux";

  # Build an lspmux-client cmd for a given server binary path
  mux = bin: [ lspmuxBin "client" "--server-path" bin ];
in
{
  lsp = {
    enable = true;
    inlayHints = true;

    servers = {
      # gh_actions_ls.enable = true;
      # java_language_server.enable = false;
      # jdtls.enable = false;
      # pylyzer.enable = false;
      # ruff_lsp.enable = false;
      # vectorcode_server.enable = true;
      # zls.enable = false;
      copilot.enable = false;
      # qmlls.enable = true;

      asm_lsp = {
        enable = true;
        cmd = mux "${lspWrappers.asm-lsp}/bin/asm-lsp";
      };

      bashls = {
        enable = true;
        package = pkgs.master.bash-language-server;
        cmd = mux "${lspWrappers.bash-language-server}/bin/bash-language-server";
      };

      ccls = {
        enable = true;
      };

      clangd = {
        enable = true;
        cmd = mux "${lspWrappers.clangd}/bin/clangd";
      };

      cssls = {
        enable = true;
        cmd = mux "${lspWrappers.vscode-css-language-server}/bin/vscode-css-language-server";
      };

      dockerls = {
        enable = true;
        cmd = mux "${lspWrappers.docker-langserver}/bin/docker-langserver";
      };

      earthlyls = {
        enable = true;
        cmd = mux "${lspWrappers.earthlyls}/bin/earthlyls";
      };

      emmet_ls = {
        enable = true;
        cmd = mux "${lspWrappers.emmet-ls}/bin/emmet-ls";
      };

      fortls = {
        enable = true;
        cmd = mux "${lspWrappers.fortls}/bin/fortls";
      };

      golangci_lint_ls = {
        enable = true;
        cmd = mux "${lspWrappers.golangci-lint-langserver}/bin/golangci-lint-langserver";
      };

      gopls = {
        enable = true;
        cmd = mux "${lspWrappers.gopls}/bin/gopls";
      };

      html = {
        enable = true;
        cmd = mux "${lspWrappers.vscode-html-language-server}/bin/vscode-html-language-server";
      };

      jsonls = {
        enable = true;
        cmd = mux "${lspWrappers.vscode-json-language-server}/bin/vscode-json-language-server";
      };

      lua_ls = {
        enable = true;
        cmd = mux "${lspWrappers.lua-language-server}/bin/lua-language-server";
      };

      nushell = {
        enable = !pkgs.stdenv.hostPlatform.isDarwin;
        cmd = if pkgs.stdenv.hostPlatform.isDarwin then [] else mux "${lspWrappers.nu-lsp}/bin/nu-lsp";
      };

      omnisharp = {
        enable = true;
        cmd = mux "${lspWrappers.omnisharp-roslyn}/bin/omnisharp";
      };

      powershell_es = {
        enable = true;
        package = pkgs.powershell-editor-services;
        cmd = mux "${lspWrappers.powershell-editor-services}/bin/powershell-editor-services";
      };

      pylsp = {
        enable = true;
        cmd = mux "${lspWrappers.pylsp}/bin/pylsp";
      };

      superhtml = {
        enable = true;
        cmd = mux "${lspWrappers.superhtml-lsp}/bin/superhtml-lsp";
      };

      systemd_ls = {
        enable = true;
        cmd = mux "${lspWrappers.systemd-language-server}/bin/systemd-language-server";
      };

      tailwindcss = {
        enable = true;
        cmd = mux "${lspWrappers.tailwindcss-language-server}/bin/tailwindcss-language-server";
      };

      taplo = {
        enable = true;
        cmd = mux "${lspWrappers.taplo-lsp}/bin/taplo-lsp";
      };

      terraformls = {
        enable = true;
        package = terraform-ls-rs;
        # Route through lspmux like the other servers so the LSP client
        # auto-attaches reliably on FileType events under Neovim 0.12+.
        # (Direct-cmd servers sometimes start for the right root but
        # never attach to the buffer.)
        cmd = mux "${terraform-ls-rs}/bin/tfls";

        # tfls-side default. Live-toggleable via the
        # <leader>F{m,o,t,?} keymaps registered on FileType=terraform
        # (see the autocmd in flake.nix). Acceptable values:
        # "minimal" (terraform fmt parity, the safe default) or
        # "opinionated" (full alphabetise / hoist / expand).
        # nixvim doesn't expose `init_options` on the typed schema for
        # this server, so route through `extraOptions` which merges
        # straight into the underlying lspconfig.setup() call.
        extraOptions = {
          init_options = {
            formatStyle = "minimal";
          };
        };
      };

      tilt_ls = {
        enable = true;
        cmd = mux "${lspWrappers.tilt-lsp}/bin/tilt-lsp";
      };
      ts_ls = {
        enable = true;
        cmd = mux "${lspWrappers.typescript-language-server}/bin/typescript-language-server";
      };
      vacuum = {
        enable = true;
        cmd = mux "${lspWrappers.vacuum-lsp}/bin/vacuum-lsp";
      };
      veryl_ls = {
        enable = true;
        cmd = mux "${lspWrappers.veryl-lsp}/bin/veryl-lsp";
      };

      helm_ls = {
        enable = true;
        filetypes = [ "helm" ];
        cmd = mux "${lspWrappers.helm_ls}/bin/helm_ls";
      };

      marksman = {
        enable = true;
        package = pkgs.stable.marksman;
        cmd = mux "${lspWrappers.marksman}/bin/marksman";
      };

      nixd = {
        enable = true;
        cmd = mux "${lspWrappers.nixd}/bin/nixd";

        settings = {
          formatting.command = [ "nixpkgs-fmt" ];
          nixpkgs.expr = "import <nixpkgs> {}";
        };
      };

      yamlls = {
        enable = true;
        filetypes = [ "yaml" ];
        cmd = mux "${lspWrappers.yaml-language-server}/bin/yaml-language-server";
        # NixVim auto-wraps yamlls settings under `yaml.` namespace.
        settings = {
          kubernetesCRDStore = {
            enable = true;
          };
        };
      };
    };
  };
}
