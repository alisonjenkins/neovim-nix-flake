# streamsearch

Bounded-memory, multi-threaded search of files of any size (including a
single multi-GB line), meant to be run as a subprocess by the Neovim
streaming viewer. Read-only on the file.

```
streamsearch [--fixed|--regex|--pcre] [--ignore-case|--smart-case] [--backward]
             [--from OFFSET] [--to OFFSET] [--limit N] [--nth N | --count]
             [--max-match-bytes N] [--threads N] [--index auto|off]
             [--progress-ms N] PATTERN FILE
```

## Contract

| Item | Behaviour |
|---|---|
| stdout | One JSON object per match, in search order, flushed as soon as the match is known: `{"start":N,"end":M}` (absolute byte offsets, `end` exclusive). A match that reached the end of the overlap window also carries `"truncated":true`: it may be longer. |
| stderr | Progress, every `--progress-ms` (default 250, 0 = off) and once at the end: `{"scanned":N,"total":T}` in bytes of the searched range. Errors are one plain line `streamsearch: ...`. |
| exit | `0` found (or `--count` finished, or stdout was closed), `1` no match, `2` error (usage, pattern, I/O). |
| `--fixed` / `--regex` / `--pcre` | Literal bytes (any bytes, NUL and invalid UTF-8 included) / Rust `regex` syntax, Unicode aware (default) / PCRE2 with JIT, byte oriented, for look-around and back-references only. `^` and `$` match at line boundaries. |
| `--ignore-case`, `--smart-case` | Smart case ignores case unless the pattern has an uppercase letter (escapes like `\S` do not count). |
| `--from OFFSET` | Forward: only matches starting at or after OFFSET. Backward: only matches starting before OFFSET (default: end of file). For `n` pass `last_start + 1`, for `N` pass `last_start`: nothing is rescanned. |
| `--to OFFSET` | Forward: only matches starting before OFFSET. Backward: only matches starting at or after OFFSET. |
| `--backward` | Chunks are scanned from the end; matches come out in descending start order. |
| `--limit N` | Stop after N matches (0 = unlimited). All other workers stop within one chunk. |
| `--nth N` | Emit only the N-th match counted from `--from` (forward or backward), then stop. Exit 1 if there are fewer than N. Chunks are counted in parallel in search order until the N-th is reached, then only that chunk is rescanned. |
| `--count` | Print `{"count":N}` for the range `[--from, --to)` and exit 0. Parallel; for a one-byte `--fixed` pattern (a newline, a comma) it is a vectorised byte count. |
| `--max-match-bytes N` | Overlap window read past every chunk (default 65536). A match must start in a chunk and fit in `N` bytes past its end to be found whole; a longer match is reported `truncated` (regex) or missed (fixed pattern longer than the window). Memory is `threads * (chunk + N)`. |
| `--threads N` | Worker threads (default: CPUs, at most 8). |
| `--chunk-bytes N` | Bytes per chunk (default 2 MiB). Tests use tiny values. |
| `--index auto|off|build` | `auto` (default) uses a valid block index to skip chunks and, after a full scan with no index, starts a detached niced build; `off` never touches the cache; `build` builds the index in the foreground, prints `{"index":PATH,"bytes":N,"blocks":M}` and exits. See Block index. |

Semantics worth knowing:

- Empty matches are never reported. Matches never overlap inside one chunk;
  a pattern that can overlap itself (`aa` in `aaa`) may report overlapping
  matches that straddle a chunk boundary.
- Files that grow are searched up to their length at start. Files that
  shrink end the affected chunks early; no crash, no error.
- The search is cancelled about 3 ms after stdout closes (a 10 ms poll tick)
  and 1 ms after SIGTERM (default action). Output is flushed per chunk, so
  the first match of a chunk appears when its chunk finishes (2 MiB).
- Peak RSS is `threads * (chunk + overlap)` plus a few MiB for the regex
  caches: about 20 MiB with the defaults, independent of file size and line
  length.

## Block index

Index = one bloom filter of trigrams per 1 MiB block (about 1% of the file,
2 hash functions, a checksum per block), stored in
`$STREAMSEARCH_CACHE_DIR`, else `$XDG_CACHE_HOME/streamsearch`, else
`~/.cache/streamsearch`, one file per canonical path (`<fnv1a(path)>.ssi`,
mode 0600). It is used when the pattern requires a case-sensitive literal of
3 bytes or more (`--fixed`, or `--regex` where a literal is required by every
match, e.g. `NEEDLE_(A|B)`, `\d+ERROR`). `--pcre` and case-insensitive
patterns never use it.

- It only ever says "definitely not in this chunk". Chunks are skipped, never
  reported; the answer is identical to an unindexed search.
- Staleness: the header stores device, inode, size, mtime and ctime in
  nanoseconds of the indexed file. Any difference, a truncated or damaged
  index file, or a bad per-block checksum means the index (or that block) is
  ignored and the chunk is scanned. Growing, rewriting in place with the
  mtime restored, and replacing the file all invalidate it.
- Built atomically (temp file, header last, rename) under a lock file, so a
  reader never sees a partial index. The build aborts if the file changes
  while it reads.
- Auto build only follows a search that consumed the whole file, for files of
  at least 64 MiB. Early exits (`--limit`, `--nth`) never trigger it. The
  index is not size-capped: budget about 1% of every indexed file. Old
  entries are not evicted; delete the cache directory to reclaim space.
- Hidden test knobs: `--index-block-bytes N`, `--index-min-bytes N`.
- When an index was used, the final progress line also carries
  `"skipped":BYTES`.

## Vim patterns

`lua/streamsearch_regex.lua` translates a Vim pattern (magic and `\v`) and
returns `{ pattern, mode = "fixed"|"regex"|"pcre", case = "ignore"|"sensitive" }`
or `nil, "untranslatable: ..."`; on `nil` fall back to `vim.regex` on the
window around the cursor.

| Vim | Engine |
|---|---|
| `\<` `\>` | `\b{start}` `\b{end}` (pcre: `\b(?=\w)`, `\b(?<=\w)`) |
| `\v` | switches to very magic while parsing; `\m` back |
| `\c` `\C` | case flag; otherwise from `ignorecase`/`smartcase` options |
| `\{n,m}` `\{-n,m}` `\{n}` `\{}` | `{n,m}` `{n,m}?` `{n}` `*` |
| `\(` `\)` `\%(` `\|` | `(` `)` `(?:` `\|` |
| `\+` `\=` `\?` | `+` `?` `?` |
| `\s \S \d \D \w \W \a \l \u \h \x \o` and negations | ASCII classes (Vim semantics) |
| `\_s` `\_.` `\_^` `\_$` | `[ \t\n]` `(?s:.)` `^` `$` |
| `\zs`, `\1`..`\9` | pcre mode only (`\K`, back-reference) |
| `~`, `\ze`, `\@=` and friends, `\%V`, `\%d`, `\M`, `\V`, `\k`, `\i`, `\f`, `\p` | untranslatable |

A pattern with no operators comes back as `mode = "fixed"`; use it, it takes
the fastest path.

## Measured

4 GiB mixed file (logs, JSON, one 1 GiB single line), 32 thread machine, 8
workers, ext4 NVMe.

| Workload | Warm | Cold (page cache dropped) |
|---|---|---|
| Absent literal, full scan | 0.09 s (46 GB/s) | 1.2 s (3.7 GB/s) |
| Literal at 40 MB, `--limit 1` | 12 ms | 23 ms |
| Literal at 2.3 GB, `--limit 1` | 52 ms | n/a |
| Regex with no literal (`[a-z]{12}`) | 0.7 s (6 GB/s) | n/a |
| `--count` newlines | 0.10 s (42 GB/s) | 1.4 s |
| `--nth 1000` newline | 12 ms | 13 ms |
| Peak RSS, any of the above | 14 to 21 MiB | 14 to 21 MiB |
| Rare literal with a warm index | 12 to 22 ms | 50 to 170 ms |

## Build and test

```
cargo build --release
cargo test --release
```

`checks.streamsearch` in the flake runs the clippy-clean unit tests, the
integration tests in `tests/search.rs` (naive-model comparison on random
data across every chunk and thread boundary, resume, backward, `--nth` and
`--count`, invalid UTF-8, NUL, empty file, cancellation latency, bounded RSS
on a 1 GiB single line) and the Lua translator tests.
