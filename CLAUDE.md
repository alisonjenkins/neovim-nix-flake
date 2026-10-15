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
- `checks.bigfile`, `checks.lazyload`, `checks.cpatches`, `checks.git-async`, `checks.git-hooks`, `checks.streamedit`, `checks.streamnav`, `checks.streamview` - headless Neovim tests in `tests/nvim/`, run by `tests/nvim/run.sh` in a throwaway repo isolated from the user's git config; `tests/nvim/fake-git` fakes network commands and holds them until the test releases them; `run.sh` exports `NVIM_BIN` (the wrapped nvim) for tests that start a second Neovim, since `vim.v.progpath` is the unwrapped binary without the config

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
- A file larger than half of `MemAvailable` (at least 256 MB; override with `vim.g.stream_viewer_min_bytes`) opens in a scratch buffer (`buftype=acwrite`, or `nofile` and read-only with `vim.g.stream_viewer_readonly = true`; `filetype=streamview`, `vim.b.bigfile`) instead of being read. `setup()` takes the read over with a `BufReadCmd`: buffer-local from `BufNew` for `:edit`, and by path at startup for files named on the command line (those buffers get no `BufNew`). A `BufReadPre` cannot cancel a read, which is why it is not used
- `:StreamView[!] [file]` forces the viewer for any file (`<leader>.v` for the current one); `:StreamGoto {byte|N%}`; `:StreamFollow` (tail -f by polling the size, any other movement stops it)
- Keys and motions: `j k <C-d> <C-u> <C-f> <C-b> <C-e> <C-y> zt zz zb + - <CR> gg G` (with counts: `{N}G` is line N, `{N}j` N lines through the file), `{count}%` a percentage of the file, and along the line `l h w W b B e E ge gE 0 ^ $ | f F t T ; ,` with counts, d/y/c with them, `dd cc yy D C Y`. `/ ? n N` search, `<C-c>` cancels a running job. `:StreamGoto {byte|N%}`, `:StreamLine N`, `:StreamIndex`, `:StreamCol {N|P%|+N|-N}`, `:StreamYank {from} {to} [file]`, `:StreamSearchAll {pat} [N]`
- Lines of any length: the buffer holds a slice (opts.slice, 2 MB) of the cursor's line, the other rows show their beginning; the cursor lives in absolute bytes of the file and the slice slides when it comes within 20% of an edge that is not the line's own (checked in the `CursorMoved` hook, `M.check_slice`). Slices start and end on UTF-8 character boundaries, NUL bytes are shown as they are. Memory is bounded: two 256 KB blocks, a window of at most ~16 MB of text, and scans in 4 MB chunks. Line starts and ends are found without a limit (`lua/streamview_nav.lua`): up to 32 MB at once, more as a job with progress, and what was scanned is remembered per file (dropped by any edit), so walking over a known long line again reads nothing; a window with a line too long to scan finds its end in the background. Motions along a line are Neovim's own for `l`/`h` inside the slice and otherwise worked out on the file with compiled loops (`ffi`; a Lua pattern with a class is ten times slower); `{N}l` counts characters, a miss of `f` is remembered per line. Operators on a line longer than the buffer (`d$`, `3dw`, `dfx`, `dd`...) act on the file: deleted from the piece table, or copied to a register up to opts.yank_max (64 MB; `:StreamYank` to a file beyond). Vim rules for inclusive/exclusive, `dw` at the end of a line, column 0 ends and `cw` are matched against Neovim's own on a normal buffer in `checks.streamnav`. Not covered: visual mode and text objects are Neovim's own inside the slice. Line numbers: checkpoints every 8 MB (opts.checkpoint_gap) in the cache directory (`Reader:index_load/save`, keyed by path, inode, size and mtime). Search: `lua/streamview_search.lua`, Vim regex through `vim.regex` in batches of whole lines or windows of a long line (overlap opts), `streamsearch` when installed. The tunables are `require("streamview").opts`
- Paths from user input go through `vim.fs.normalize`, not `expand()`: this config's `wildignore` makes `expand("x.bin")` return an empty string
- Editing: the reader serves a piece table (pieces of the file or of typed text), and every read goes through its block cache. The window's lines are diffed against what was shown (`vim.diff`) and become one undoable edit whenever the window moves, is redrawn or is saved, so memory grows with the typed text only (warning at 256 MB, refused at 1 GB: `opts.edit_warn`/`edit_max`). `u`/`<C-r>` undo what is typed in the window first, then earlier edits wherever they are; Neovim's own undo history is cleared on every window move. Lines shown cut, with NUL bytes or not whole are read-only (the change is undone with a message); CRLF, a missing final newline and invalid UTF-8 bytes are kept byte for byte. In a hunk that spans lines with mixed CR/LF endings, the first line's ending is used for all
- Saving (`:w`, `:w other`, `:StreamWrite[!] [path]`): streams the pieces into a temp file next to the target (same mode and owner), fsyncs and renames it over the file, in 10 ms slices with progress in the winbar and `<C-c>` to cancel; failure or cancel removes the temp file and leaves the original. Refuses if the file changed on disk since it was opened (size, mtime, inode) or the target exists, unless `!`. With less free space than the new size it asks to patch in place (pwrite), only if every edit kept its length. The save finishes after the command returns, so `:wq` does not quit: `:w`, then `:q` (a modified viewer refuses `:q` and leaving without `!`). The edit history ends with the save. Not preserved: xattrs, ACLs, hard links
- `tests/nvim/streamview.lua` (`checks.streamview`, read-only mode), `tests/nvim/streamedit.lua` (`checks.streamedit`) and `tests/nvim/streamnav.lua` (`checks.streamnav`: slices, motions and operators against Neovim's own, line counting, search, a 1 GB line) fake "bigger than RAM" with a small threshold, and check Lua memory over sparse files. Keys typed in a test go through `:normal` after one `nvim_input("\r")` step, because a message printed at startup leaves a hit-enter prompt that takes the first keys

### Streaming Search Helper
`streamsearch/` is a Rust binary (`streamsearch` on the wrapper's PATH) that the streaming viewer runs as a subprocess to search files larger than RAM, including single multi-GB lines. Callers keep a pure-Lua chunk scan as the fallback when `vim.fn.executable("streamsearch") == 0`.
- Contract: `streamsearch [--fixed|--regex|--pcre] [--ignore-case|--smart-case] [--backward] [--from OFFSET] [--to OFFSET] [--limit N] [--nth N | --count] [--max-match-bytes N] [--threads N] [--index auto|off] [--progress-ms N] PATTERN FILE`. Stdout is JSON lines `{"start":N,"end":M}` (absolute byte offsets, search order, flushed per chunk); stderr is `{"scanned":N,"total":T}` progress; exit 0 found, 1 none, 2 error. `--nth N` emits the N-th match from `--from`; `--count` prints `{"count":N}` for `[--from, --to)`. Full reference in `streamsearch/README.md`
- `--from` resumes: forward matches start at or after it, backward matches start before it, so `n`/`N` never rescan
- A match must fit in `--max-match-bytes` (default 64 KiB) past its chunk; longer regex matches come back with `"truncated":true`
- `lua/streamsearch_regex.lua` translates Vim patterns (`\<`, `\>`, `\v`, `\c`, `\{n,m}`, `\(`) and returns `nil, "untranslatable: ..."` when the caller must fall back to `vim.regex`
- `checks.streamsearch` runs the Lua translator tests against the built binary; the cargo tests (`tests/search.rs`, a naive-model comparison plus cancellation and bounded-RSS checks) run in the package's `checkPhase`

### Custom Lua Setup
Extra Lua configuration in `extraConfigLua` sets up safe directories for backups, swap files, and undo files outside of git repositories.

### Code Organization Standards
- **Alphabetical Ordering**: Maintain alphabetical order for plugins and attributes wherever possible unless it would break functionality
  - `extraPlugins` - Keep plugin list alphabetically sorted
  - `extraPackages` - Keep package list alphabetically sorted
  - `plugin-config` imports - Keep import statements alphabetically sorted
  - `keymaps` imports - Keep keymap imports alphabetically sorted
  - Exception: Base configuration objects (e.g., `auto-session` in plugin-config merges) should remain at the top for functionality