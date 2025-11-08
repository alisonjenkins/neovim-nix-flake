# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Common Development Commands

### Build and Test
- `nix build` - Build the Neovim configuration
- `nix run .` - Run the built Neovim configuration
- `nix flake check` - Validate the flake and run tests
- `just update` or `just u` - Update flake inputs and commit lock file

### Development Workflow
- `nix develop` - Enter development shell with `just` and `nix-fast-build`
- `just list` - Show all available just commands

## Architecture Overview

This is a **NixVim-based Neovim configuration** packaged as a Nix flake. The configuration is highly modular and declarative.

### Core Structure

**Main Configuration (`flake.nix:21-375`):**
- Single large configuration object passed to NixVim
- Declarative plugin configuration using NixVim's options system
- Performance optimizations with `combinePlugins` and `byteCompileLua`

**Modular Organization:**
- `keymaps/` - Keymap definitions organized by functionality (ai, git, lsp, etc.)
- `plugin-config/` - Individual plugin configurations in separate Nix files  
- `colorschemes/` - Theme configurations (currently using bamboo)
- `ftplugin/` - Filetype-specific configurations

### Key Architecture Patterns

**Plugin Configuration Pattern:**
```nix
// (import ./plugin-config/pluginname { inherit pkgs; })
```
Each plugin gets its own directory with a `default.nix` file that exports configuration.

**Keymap Organization:**
Keymaps are imported as lists and concatenated:
```nix
keymaps = [ ]
  ++ import ./keymaps/ai/avante
  ++ import ./keymaps/lsp
  // ...
```

**Package Management:**
- `extraPackages` - CLI tools and language servers available in Neovim's PATH
- `extraPlugins` - Custom/external vim plugins not in nixpkgs
- Overlay system for package version pinning (master, stable, unstable)

### Language Support

**Configured LSP Servers (`plugin-config/lsp/default.nix`):**
- Go: gopls, golangci-lint-ls
- Python: pylsp  
- Rust: rustaceanvim (separate from LSP config)
- JavaScript/TypeScript: ts_ls
- Terraform: terraformls, tflint
- Nix: (via nixd - check LSP config)
- Bash: bashls
- Many others (CSS, HTML, JSON, Docker, etc.)

**Key Development Features:**
- DAP debugging support for multiple languages
- Treesitter for syntax highlighting
- AI assistance via Avante, CodeCompanion, and Copilot
- HTTP client via Kulala
- Database tools via vim-dadbod
- Git integration via Fugitive and custom keymaps
- Testing framework integration via Neotest

### Testing Environment

The `tests/` directory contains example projects for testing language-specific features:
- `tests/python/` - Python project with nox testing setup
- `tests/rest/` - HTTP testing files

## Important Implementation Notes

### Performance Configuration
- `combinePlugins.enable = true` - Combines compatible plugins for faster startup
- `byteCompileLua.enable = true` - Pre-compiles Lua for performance
- Some plugins are explicitly excluded from combining via `standalonePlugins`
- **AV Optimization**: See `DEFENDER_OPTIMIZATION.md` for Microsoft Defender and anti-virus specific optimizations
  - Deferred LSP attachment (150ms delay)
  - ShaDa file lazy loading (200ms delay)
  - Optimized filesystem polling and wildignore patterns
  - Treesitter module lazy loading

### Version Management  
- Uses three nixpkgs channels: unstable (default), stable, and master
- Custom plugin versions pinned via overlays
- Renovate bot configured for dependency updates

### Custom Lua Setup
Extra Lua configuration in `extraConfigLua` sets up safe directories for backups, swap files, and undo files outside of git repositories.