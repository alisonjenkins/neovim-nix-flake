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

### GitHub Actions & CI/CD
- **build-and-cache.yaml**: Runs `nix flake check` and builds on pull requests and pushes to main; only pushes to main upload to Cachix
- **update.yaml**: Updates flake lock file on schedule or manual trigger
- **trigger-nix-config-update.yaml**: Triggers updates on `alisonjenkins/nix-config` repository when changes merge to main
  - Requires `NIX_CONFIG_TRIGGER_TOKEN` secret (GitHub PAT with repo or Actions permissions)

Note: `just update` requires 1Password CLI (`op`) for GitHub authentication token retrieval.

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
- AI assistance via claudecode.nvim (primary, `<leader>ac*`) and sidekick.nvim (`<leader>as*`). The avante, codecompanion and copilot-lua configs in `plugin-config/` are not imported, so those plugins are off; copilot inline completion is off until AI completion is revisited
- HTTP client via Kulala
- Database tools via vim-dadbod
- Git integration via Fugitive and custom keymaps
- Testing framework integration via Neotest

### Testing Environment

Automated tests run as flake checks (`nix flake check`, and in CI):
- `checks.default` - nixvim startup check; fails on any startup error or evaluation warning
- `checks.treefmt` - formatting (`nix fmt` fixes it)
- `checks.terraform-tools` - `tests/lua/test_terraform_tools.lua` under luajit
- `checks.bigfile`, `checks.lazyload`, `checks.cpatches`, `checks.git-async`, `checks.git-hooks`, `checks.streamview` - headless Neovim tests in `tests/nvim/`, run by `tests/nvim/run.sh` in a throwaway repo isolated from the user's git config; `tests/nvim/fake-git` fakes network commands and holds them until the test releases them; `run.sh` exports `NVIM_BIN` (the wrapped nvim) for tests that start a second Neovim, since `vim.v.progpath` is the unwrapped binary without the config

The `tests/` directory also contains example projects for trying language-specific features by hand:
- `tests/python/` - Python project with nox testing setup
- `tests/rest/` - HTTP testing files

## Important Implementation Notes

### Performance Configuration
- `combinePlugins.enable = true` - Combines compatible plugins for faster startup
- `byteCompileLua.enable = true` - Pre-compiles Lua for performance
- Some plugins are explicitly excluded from combining via `standalonePlugins`
- Startup events: `DeferredUIEnter` (lz.n) loads the light deferred plugins; `User DeferredStage2` (fired 10 ms later from `extraConfigLuaPre`) loads modicator, smear-cursor and fidget, and `User DeferredStage3` (10 ms after that) loads neotest, so the batch does not block for ~30 ms. Headless tests fire all three (`tests/nvim/harness.lua`). pipeline.nvim loads on its first `:Pipeline`/`:GhActions`, in the directory Neovim started in
- Do not lazy-load a plugin on `cmd`/`keys` if another start plugin lists it as a dependency (neotest is one of the adapters' dependencies): its `plugin/` files run at startup and define the real command, so the lz.n stub never loads it and `setup()` never runs. Use an event; `tests/nvim/lazyload.lua` checks neotest
- claudecode.nvim is an opt plugin (`optional = true`) that lz.n loads in `User DeferredStage3` (or on its first `:ClaudeCode*` command), because its `plugin/` file would run `setup()` during startup. `setup()` starts the server and the `~/.claude/ide` lock file that a separately launched `claude` connects to, so it must not wait for a command. Both it and sidekick use tmux only when `$TMUX` is set. `claude` comes from `extraPackages`. Neovim's own autoread watcher reloads files an agent rewrites; `lazyload.lua` pins that
- `combinePlugins` keeps treesitter grammars/queries and the `async` pair (promise-async, async.nvim) out of the pack: their files overlap and `buildEnv` rejects that
- `packpath` is trimmed to entries holding `pack`/`start`/`opt` directories in `extraConfigLuaPre`
- **AV Optimization**: See `DEFENDER_OPTIMIZATION.md` for Microsoft Defender and anti-virus specific optimizations
  - Deferred LSP attachment (150ms delay)
  - ShaDa file lazy loading (200ms delay)
  - Optimized filesystem polling and wildignore patterns
  - Treesitter module lazy loading

### Version Management
- Uses three nixpkgs channels: unstable (default), stable, and master
- Overlay system defined in flake.nix allows mixing packages from different channels
- Custom plugin versions pinned via overlays
- Renovate bot (`renovate.json`) automatically creates PRs for dependency updates
- The nightly overlay pins its own Neovim source, so `nix flake update` alone leaves Neovim behind: also run `nix flake update neovim-nightly-overlay/neovim-src`
- Three Neovim C patches (very-long-line fixes) are applied to `neovim-unwrapped` by an overlay in `flake.nix`. Each is a PR on our fork, https://github.com/alisonjenkins/neovim/pulls (#1 `readfile`, #2 Insert `start_textlen`, #3 ASCII runs), fetched by commit with `fetchpatch2` (news.txt and tests excluded). The PRs are the reminder to upstream them to `neovim/neovim`; they are not submitted there yet. To change one, push a new commit to its fork branch and bump `rev` and `hash` in the overlay. If one stops applying after a nightly update, rebase the fork branch, or drop it once upstream has the fix
- Ten more Neovim C commits from fork PR #4 (runtime path scans: wildcard expansion, 'runtimepath' resolution, script lookup) are applied after those three, in order, each with its own `rev`/`hash`. Real-config startup instructions drop about 35%
- Four libtree-sitter commits (query analysis, about 3.9x fewer instructions, TypeScript first open about 65 ms faster) come from https://github.com/alisonjenkins/tree-sitter/pull/1, also fork-only, fetched by commit with the tests excluded. The overlay overrides only the `tree-sitter` that `neovim-unwrapped` links, never the global attribute (that would rebuild every grammar). Bump the four `rev`/`hash` pairs after pushing to the fork branch

### Large Files
- Files over 1 MB get `vim.b.bigfile` in the `BufReadPre` gate in `flake.nix` (snacks `bigfile` also sets it for long-line files). Per-buffer scanners that walk the whole text must check it: smartcolumn, nvim-ufo's `provider_selector`, conform (`disable_autoformat`), smear-cursor
- Over 1 MB `modeline` is off for the buffer: vim-sleuth parses modelines before it reads `b:sleuth_automatic`
- `incsearch`, `inccommand` and smear-cursor are global, so they are switched off on entering a big buffer and put back to the user's values on leaving
- `tests/nvim/bigfile.lua` (`checks.bigfile`) pins all of the above, each assertion next to its small-file control
- Files above the stream-viewer threshold are not loaded at all (see below); the `bigfile` gating above covers the files that are still loaded

#### Stream viewer (`lua/streamview.lua`)
- A file larger than half of `MemAvailable` (at least 256 MB; override with `vim.g.stream_viewer_min_bytes`) opens in a read-only scratch buffer (`buftype=nofile`, `filetype=streamview`, `vim.b.bigfile`) instead of being read. `setup()` takes the read over with a `BufReadCmd`: buffer-local from `BufNew` for `:edit`, and by path at startup for files named on the command line (those buffers get no `BufNew`). A `BufReadPre` cannot cancel a read, which is why it is not used
- `:StreamView[!] [file]` forces the viewer for any file (`<leader>.v` for the current one); `:StreamGoto {byte|N%}`; `:StreamFollow` (tail -f by polling the size, any other movement stops it)
- Keys: `j k <C-d> <C-u> <C-f> <C-b> gg G`, `{count}%` jumps to a percentage, `zL`/`zH` page sideways within a line, `/ ? n N` search, `<C-c>` cancels a running search. Search is literal text (no regex), scanned in 10 ms slices with progress in the winbar. rg/grep are not used: they hold a whole line in memory, which breaks the bounded-memory guarantee on line-less data
- Memory is bounded: the reader keeps two 256 KB blocks; a window is rebuilt from a byte offset. Lines are cut at `\n` or at multiples of 16 MB (so a line never needs more than one segment of scanning, and the cuts depend only on the contents); at most 64 KB of a line is shown, with a `[+N bytes]` marker. The tunables are `require("streamview").opts`
- Paths from user input go through `vim.fs.normalize`, not `expand()`: this config's `wildignore` makes `expand("x.bin")` return an empty string
- `tests/nvim/streamview.lua` (`checks.streamview`) fakes "bigger than RAM" with a small threshold, and checks Lua memory over a 512 MB sparse file

### Custom Lua Setup
Extra Lua configuration in `extraConfigLua` sets up safe directories for backups, swap files, and undo files outside of git repositories.

### Code Organization Standards
- **Alphabetical Ordering**: Maintain alphabetical order for plugins and attributes wherever possible unless it would break functionality
  - `extraPlugins` - Keep plugin list alphabetically sorted
  - `extraPackages` - Keep package list alphabetically sorted
  - `plugin-config` imports - Keep import statements alphabetically sorted
  - `keymaps` imports - Keep keymap imports alphabetically sorted
  - Exception: Base configuration objects (e.g., `auto-session` in plugin-config merges) should remain at the top for functionality