{ pkgs, ... }:
let
  lspmuxBin = "${pkgs.lspmux}/bin/lspmux";

  # Build an lspmux-client cmd for a given server binary path
  mux = bin: [ lspmuxBin "client" "--server-path" bin ];

  # Create a wrapper script so servers that need extra startup args can be
  # referenced as a single binary path by lspmux.
  mkWrapper = scriptName: fullShellCmd:
    pkgs.writeShellScriptBin scriptName "exec ${fullShellCmd}";

  # Servers that require subcommands or flags to start in LSP mode:
  bashLsWrapped = mkWrapper "bash-language-server"
    "${pkgs.master.bash-language-server}/bin/bash-language-server start";
  cssLsWrapped = mkWrapper "vscode-css-language-server"
    "${pkgs.vscode-langservers-extracted}/bin/vscode-css-language-server --stdio";
  dockerLsWrapped = mkWrapper "docker-langserver"
    "${pkgs.dockerfile-language-server}/bin/docker-langserver --stdio";
  helmLsWrapped = mkWrapper "helm_ls"
    "${pkgs.helm-ls}/bin/helm_ls serve";
  htmlLsWrapped = mkWrapper "vscode-html-language-server"
    "${pkgs.vscode-langservers-extracted}/bin/vscode-html-language-server --stdio";
  jsonLsWrapped = mkWrapper "vscode-json-language-server"
    "${pkgs.vscode-langservers-extracted}/bin/vscode-json-language-server --stdio";
  nushellLsWrapped = mkWrapper "nu-lsp"
    "${pkgs.nushell}/bin/nu --lsp";
  superHtmlLsWrapped = mkWrapper "superhtml-lsp"
    "${pkgs.superhtml}/bin/superhtml lsp";
  tailwindLsWrapped = mkWrapper "tailwindcss-language-server"
    "${pkgs.tailwindcss-language-server}/bin/tailwindcss-language-server --stdio";
  taploLsWrapped = mkWrapper "taplo-lsp"
    "${pkgs.taplo}/bin/taplo lsp stdio";
  terraformLsWrapped = mkWrapper "terraform-ls"
    "${pkgs.terraform-ls}/bin/terraform-ls serve";
  tflintLsWrapped = mkWrapper "tflint-langserver"
    "${pkgs.tflint}/bin/tflint --langserver";
  tiltLsWrapped = mkWrapper "tilt-lsp"
    "${pkgs.tilt}/bin/tilt lsp server";
  tsLsWrapped = mkWrapper "typescript-language-server"
    "${pkgs.typescript-language-server}/bin/typescript-language-server --stdio";
  vacuumLsWrapped = mkWrapper "vacuum-lsp"
    "${pkgs.vacuum-go}/bin/vacuum language-server";
  verylLsWrapped = mkWrapper "veryl-lsp"
    "${pkgs.veryl}/bin/veryl lsp";
  yamlLsWrapped = mkWrapper "yaml-language-server"
    "${pkgs.yaml-language-server}/bin/yaml-language-server --stdio";
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
      asm_lsp = {
        enable = true;
        cmd = mux "${pkgs.asm-lsp}/bin/asm-lsp";
      };
      bashls = {
        enable = true;
        package = pkgs.master.bash-language-server;
        cmd = mux "${bashLsWrapped}/bin/bash-language-server";
      };
      clangd = {
        enable = true;
        cmd = mux "${pkgs.clang-tools}/bin/clangd";
      };
      copilot.enable = false;
      cssls = {
        enable = true;
        cmd = mux "${cssLsWrapped}/bin/vscode-css-language-server";
      };
      dockerls = {
        enable = true;
        cmd = mux "${dockerLsWrapped}/bin/docker-langserver";
      };
      earthlyls = {
        enable = true;
        cmd = mux "${pkgs.earthlyls}/bin/earthlyls";
      };
      emmet_ls = {
        enable = true;
        cmd = mux "${pkgs.emmet-ls}/bin/emmet-ls";
      };
      fortls = {
        enable = true;
        cmd = mux "${pkgs.fortls}/bin/fortls";
      };
      golangci_lint_ls = {
        enable = true;
        cmd = mux "${pkgs.golangci-lint-langserver}/bin/golangci-lint-langserver";
      };
      gopls = {
        enable = true;
        cmd = mux "${pkgs.gopls}/bin/gopls";
      };
      html = {
        enable = true;
        cmd = mux "${htmlLsWrapped}/bin/vscode-html-language-server";
      };
      jsonls = {
        enable = true;
        cmd = mux "${jsonLsWrapped}/bin/vscode-json-language-server";
      };
      lua_ls = {
        enable = true;
        cmd = mux "${pkgs.lua-language-server}/bin/lua-language-server";
      };
      nushell = {
        enable = true;
        cmd = mux "${nushellLsWrapped}/bin/nu-lsp";
      };
      pylsp = {
        enable = true;
        cmd = mux "${pkgs.python3Packages.python-lsp-server}/bin/pylsp";
      };
      # qmlls.enable = true;
      superhtml = {
        enable = true;
        cmd = mux "${superHtmlLsWrapped}/bin/superhtml-lsp";
      };
      systemd_ls = {
        enable = true;
        cmd = mux "${pkgs.systemd-language-server}/bin/systemd-language-server";
      };
      tailwindcss = {
        enable = true;
        cmd = mux "${tailwindLsWrapped}/bin/tailwindcss-language-server";
      };
      taplo = {
        enable = true;
        cmd = mux "${taploLsWrapped}/bin/taplo-lsp";
      };
      terraformls = {
        enable = true;
        # Not routed through lspmux: terraform-ls fails to attach when proxied
        cmd = [ "${pkgs.terraform-ls}/bin/terraform-ls" "serve" ];
      };
      tflint = {
        enable = true;
        cmd = mux "${tflintLsWrapped}/bin/tflint-langserver";
      };
      tilt_ls = {
        enable = true;
        cmd = mux "${tiltLsWrapped}/bin/tilt-lsp";
      };
      ts_ls = {
        enable = true;
        cmd = mux "${tsLsWrapped}/bin/typescript-language-server";
      };
      vacuum = {
        enable = true;
        cmd = mux "${vacuumLsWrapped}/bin/vacuum-lsp";
      };
      veryl_ls = {
        enable = true;
        cmd = mux "${verylLsWrapped}/bin/veryl-lsp";
      };

      helm_ls = {
        enable = true;
        filetypes = [ "helm" ];
        cmd = mux "${helmLsWrapped}/bin/helm_ls";
      };

      marksman = {
        enable = true;
        package = pkgs.stable.marksman;
        cmd = mux "${pkgs.stable.marksman}/bin/marksman";
      };

      nixd = {
        enable = true;
        cmd = mux "${pkgs.nixd}/bin/nixd";

        settings = {
          formatting.command = [ "nixpkgs-fmt" ];
          nixpkgs.expr = "import <nixpkgs> {}";
        };
      };

      yamlls = {
        enable = true;
        filetypes = [ "yaml" ];
        cmd = mux "${yamlLsWrapped}/bin/yaml-language-server";
      };
    };
  };
}
