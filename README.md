# neovim-nix-flake
My Neovim config and environment ported to a Nix Flake

## Known Issues

### LSPConfig Deprecation Warning (Neovim 0.11+)

A deprecation warning filter has been added to suppress the `require('lspconfig')` deprecation message that appears in Neovim 0.11. This is a temporary workaround until Nixvim migrates to the new `vim.lsp.config` API. See [neovim/nvim-lspconfig#3232](https://github.com/neovim/nvim-lspconfig/pull/3232) for more details.

The filter is implemented in `flake.nix` under `extraConfigLua` and can be removed once Nixvim has been updated to use the new API.
