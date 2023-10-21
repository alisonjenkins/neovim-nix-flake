# vim: ft=lua
{ pkgs }:
''
    local nvim_lsp = require('lspconfig')
    nvim_lsp.tsserver.setup({
      init_options = {
        tsserver = {
        path = "${pkgs.nodePackages.typescript}/lib/node_modules/typescript/lib",
      },
    },
  })
''
