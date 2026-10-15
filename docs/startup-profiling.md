# Startup profiling

Profile of the real config (all plugins enabled), 2026-10-15. Machine: 32 cores, load average about 4, so absolute numbers are noisy. Gains are interleaved A/B runs or medians of 10 to 60.

## Result

| Metric | Before | After | Method |
|---|---|---|---|
| Headless `+qa` wall | 95.4 ms | 72.2 ms | A/B, n=60 |
| Headless user / sys CPU | 57.6 / 44.3 ms | 46.9 / 25.9 ms | n=30 |
| `statx` / `access` / `readlink` calls | 13.6k / 4.7k / 2.8k | 5.2k / 1.7k / 1.6k | `strace -c` |
| runtimepath entries | 116 | 18 | |
| Real UI: `--cmd` to `VimEnter` | 61 ms | 50 ms | tmux pty, median of 10 |
| Real UI: blocking `DeferredUIEnter` batch | 43 ms | 7.2 ms, then about 12 ms ten ms later | median of 10 |
| Real UI: `UIEnter` to batch start | 34 ms | 22 ms | median of 10 |

Fixed costs: the wrapper script adds 2.6 ms; plain `nvim -u NONE` takes 3 ms. Headless `+qa` never fires `UIEnter`, so the headless numbers exclude the deferred work; the real-UI numbers include it.

## Commits

| Commit | Change | Gain |
|---|---|---|
| `combinePlugins` re-enabled | It had been `enable = false` although this file said true. Treesitter grammars and queries, and `promise-async`/`async.nvim`, stay out of the pack because their files overlap. | headless 96 to 83 ms, deferred batch 43 to 30 ms |
| three-stage `DeferredUIEnter` | modicator, smear-cursor and fidget load on `User DeferredStage2`, 10 ms later; neotest (its `setup()` requires seven adapter modules, about 12 ms) on `User DeferredStage3`, 10 ms after that. neotest cannot use a `cmd` trigger: it is a dependency of its adapter plugins, so its `plugin/` files define `:Neotest` at startup and the lz.n stub never runs `setup()` | one block of about 29 ms becomes 8.4 + 12 + 12 ms |
| pipeline.nvim lazy | setup runs on the first `:Pipeline` or `:GhActions`, in the directory Neovim started in (it reads that directory's git remotes) | removes 4 to 12 ms |
| trimmed `packpath` | drop entries without `pack`, `start` or `opt` directories; runtimepath identical | headless 80.4 to 76.9 ms |

## Where the time goes now

| Item | Cost |
|---|---|
| Treesitter query construction on first open of a file type (libtree-sitter query analysis, 23 to 25% of file-open CPU) | blocking: ts 124 ms (injections 51, highlights 42, rainbow-delimiters 9), md 118, rust 89, go 56, py 54, nix 43, yaml 36, lua 33, tf 30, json 27 |
| `otter.activate` on the first Markdown file, in an `LspAttach` callback about 190 ms after open | 60 ms |
| Markdown first open: `obsidian.setup`, `image.setup`, tmux and kitty probing | 9 + 6 + 6.7 ms |
| LuaJIT running config and plugin Lua, about 45% of startup CPU, spread thin (blink-cmp 3.8, lualine 3.0, ufo 2.9, devicons 2.0, telescope 2.0, oil 1.4) | about 25 ms |
| About 5k filesystem syscalls, mostly runtimepath and `require` probes (lualine alone 699 `statx`) | 26 ms sys |
| About 5 process spawns (blink.cmp `git describe` and `rev-parse` even with `download = false`, gitsigns, lspmux) | about 0.6 ms each |
| `mini.starter` refresh when the fortune job returns (bare `nvim` only) | 17 ms stall |

First LSP attach lands 40 to 300 ms after the open returns.

## Neovim C code (symbolised RelWithDebInfo build, real config on top)

Startup through `DeferredUIEnter` costs 56 ms of user CPU; one file open about 50 ms more.

| Startup share | Cost |
|---|---|
| LuaJIT VM running config and plugin Lua | 45.7% |
| libc string and mem functions | 11.1% |
| libc syscall wrappers | 4.7% |
| malloc and free | 3.4% |
| path expansion, inclusive (`gen_expand_wildcards_and_cb`) | 8.1% |
| shada read and write | 2.2% |

File open: libtree-sitter 22.8% self, `tslua_parse_query` 25% inclusive, LuaJIT 28.6%, `do_cmdline` 7.6% inclusive. Idle and typing: LuaJIT 52%, then the treesitter highlighter, `ts_tree_root_node` and `update_screen` 4%.

Findings, none shipped:

- `add_pack_dir_to_rtp` calls `fix_fname` (realpath) on every runtimepath entry for every start package, so it is O(n^2): 182 `realpath` and about 1600 `readlink` calls at startup with 17 start packages, far worse with the old 106 entries. Fix: cache resolved entries during `load_start_packages`.
- `runtime_search_path_build` runs 3 times at startup; each is about 6M instructions and 700 syscalls and globs every `packpath` entry twice.
- `do_in_cached_path` and `gen_expand_wildcards_and_cb` run about 3500 times at startup, about 17k instructions each, to stat literal names. A literal-path fast path could save 3 to 4 ms.
- Negative lookups in `nvim_get_runtime_file` and `require` are never cached (a `stat` per runtimepath entry per call). Caching needs invalidation semantics.
- Rejected: `path_has_wildcard` with `strcspn`. Callgrind +0.6% instructions, wall time equal.
- `ts_query_new` is in libtree-sitter, not in Neovim.

Caveats: `perf` ran user-space only (`perf_event_paranoid=2`), so kernel time shows in the strace and sys numbers, not the flamegraphs. libluajit and libtree-sitter are stripped, so Lua VM and query-analysis time is only lumped into categories. Callgrind inclusive numbers are unusable under LuaJIT's JIT.

## Not changed, and why

- Treesitter query cost: trimming queries changes highlighting.
- `otter.activate`: the feature is wanted; deferring moves the freeze.
- Eager setups of telescope (2.0 ms), remote-nvim (0.9), render-markdown (0.8), tiny-devicons-auto-colors (0.75): lazy loading saves about 4 to 5 ms with some behaviour risk, untested interactively.
- `vim.loader`: disabling it was neutral with a warm cache.
- blink.cmp git calls: removing them needs a plugin patch.

## Remaining ideas, by expected gain

1. Lighter or trimmed treesitter injection queries for ts and js: about 50 ms per first open, changes highlighting.
2. Run `otter.activate` for Markdown only on the first embedded-code interaction: about 60 ms.
3. Lazy-load telescope, remote-nvim, render-markdown, tiny-devicons-auto-colors: about 4 to 5 ms.
4. Skip blink.cmp's startup `git describe` and `rev-parse`: about 2 ms, needs a plugin patch.
5. Patch Neovim `add_pack_dir_to_rtp` and add the literal-path glob fast path: about 3 to 4 ms for combined configs, far more with many start packages; needs upstream tests.
6. Replace the `mini.starter` refresh after the fortune job with a header-only update: 17 ms stall on a bare `nvim`.
