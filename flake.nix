{
  description = "Alison Jenkins's Neovim Flake";

  inputs = {
    flake-parts.url = "github:hercules-ci/flake-parts";
    # neovim-nightly-overlay.url = "github:nix-community/neovim-nightly-overlay";
    nixpkgs-master.url = "github:nixos/nixpkgs";
    nixpkgs-stable.url = "github:nixos/nixpkgs/nixos-25.11";
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    nixvim.url = "github:nix-community/nixvim";
    # nixvim.url = "github:alisonjenkins/nixvim/fix/sidekick-nes-disabled";
    terraform-ls-rs = {
      url = "github:alisonjenkins/terraform-ls-rs";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    treefmt-nix.url = "github:numtide/treefmt-nix";
  };

  outputs =
    { flake-parts
    , nixvim
    , ...
    } @ inputs:
    let
      config = { pkgs, lspWrappers, ... }:
        {
          imports = [
            ./modules/plugins/schema-companion.nix
          ];

          editorconfig.enable = true;
          enableMan = false;
          luaLoader.enable = true;
          # package =
          #   inputs.neovim-nightly-overlay.packages.${pkgs.system}.default;

          autoCmd = [
            {
              event = [ "TextYankPost" ];
              pattern = [ "*" ];
              command = "silent! lua vim.hl.on_yank()";
            }
            {
              event = [ "BufEnter" ];
              pattern = [ "github.com_*.txt" ];
              command = "set filetype=markdown";
            }
            {
              event = "FileType";
              pattern = "helm";
              command = "LspRestart";
            }
            {
              event = [ "BufRead" "BufNewFile" ];
              pattern = [ "*.tf" "*.tfvars" "*.hcl" "*.tofu" ];
              command = "set filetype=terraform";
            }
            {
              event = "VimEnter";
              once = true;
              callback.__raw = ''
                function()
                  -- Start lspmux daemon; silently fails if already running (port already bound)
                  vim.fn.jobstart({ "${pkgs.lspmux}/bin/lspmux", "server" }, { detach = true })
                end
              '';
            }
            # Terraform format-style toggle. Buffer-local keymaps so
            # the bindings only conflict with other servers' keys
            # when a `.tf` / `.tfvars` / `.hcl` / `.tofu` buffer is
            # active. tfls reads `formatStyle` from a live config
            # cell, so the change takes effect on the very next
            # save / `:Format` — no restart needed.
            {
              event = "FileType";
              pattern = "terraform";
              callback.__raw = ''
                function(args)
                  local bufnr = args.buf
                  -- Track the per-session style on a global so the
                  -- "toggle" mapping can flip it without re-querying
                  -- the server. Defaults to the init_options value.
                  if vim.g.tfls_format_style == nil then
                    vim.g.tfls_format_style = "minimal"
                  end

                  local function notify_style(style)
                    vim.g.tfls_format_style = style
                    -- Reach the tfls client (id-agnostic) and push the
                    -- new style via `workspace/didChangeConfiguration`.
                    -- Fan out to every attached client whose name
                    -- looks like the terraform LSP — covers both the
                    -- nixvim default `terraformls` ID and any custom
                    -- name the user might pick.
                    local sent = false
                    for _, client in ipairs(vim.lsp.get_clients({ bufnr = bufnr })) do
                      local name = client.name or ""
                      if name:match("terraform") or name:match("tfls") then
                        client:notify("workspace/didChangeConfiguration", {
                          settings = {
                            ["terraform-ls-rs"] = { formatStyle = style },
                          },
                        })
                        sent = true
                      end
                    end
                    if sent then
                      vim.notify("tfls formatStyle = " .. style, vim.log.levels.INFO)
                    else
                      vim.notify(
                        "tfls not attached — formatStyle update queued via vim.g.tfls_format_style",
                        vim.log.levels.WARN
                      )
                    end
                  end

                  -- `<leader>F` (capital F = Format) is free in this
                  -- config; the lowercase `<leader>t` prefix is taken
                  -- by Testing. Buffer-local registration ensures the
                  -- keys are inert outside terraform buffers.
                  vim.keymap.set("n", "<leader>Fm", function()
                    notify_style("minimal")
                  end, { buffer = bufnr, desc = "tfls: formatStyle = minimal (terraform fmt)" })

                  vim.keymap.set("n", "<leader>Fo", function()
                    notify_style("opinionated")
                  end, { buffer = bufnr, desc = "tfls: formatStyle = opinionated (alphabetise + hoist)" })

                  vim.keymap.set("n", "<leader>Ft", function()
                    local next_style = vim.g.tfls_format_style == "opinionated"
                      and "minimal"
                      or "opinionated"
                    notify_style(next_style)
                  end, { buffer = bufnr, desc = "tfls: toggle formatStyle (minimal <-> opinionated)" })

                  vim.keymap.set("n", "<leader>F?", function()
                    vim.notify(
                      "tfls formatStyle = " .. (vim.g.tfls_format_style or "minimal"),
                      vim.log.levels.INFO
                    )
                  end, { buffer = bufnr, desc = "tfls: show current formatStyle" })
                end
              '';
            }
          ];

          extraConfigLua = ''
            -- `:Format` — routes through conform with
            -- `lsp_format = "fallback"`, which uses LSP when the
            -- buffer's filetype has no conform formatters.
            -- Range form: `:1,20Format`. Logs decision points to
            -- /tmp/format-trace.log so we can see WHICH branch
            -- conform took.
            vim.api.nvim_create_user_command("Format", function(opts)
              local conform = require("conform")
              local lsp_fmt = require("conform.lsp_format")
              local bufnr = vim.api.nvim_get_current_buf()
              local trace = io.open("/tmp/format-trace.log", "a")
              local function T(m)
                if trace then
                  trace:write(os.date("%H:%M:%S") .. " " .. m .. "\n")
                  trace:flush()
                end
              end
              T("=== :Format invoked range=" .. tostring(opts.range))
              T("buf: " .. vim.api.nvim_buf_get_name(bufnr))
              T("ft: " .. vim.bo[bufnr].filetype)
              local fmt_clients = lsp_fmt.get_format_clients({ bufnr = bufnr })
              T("conform get_format_clients: " .. tostring(#fmt_clients))
              for _, c in ipairs(fmt_clients) do T("  " .. c.name) end
              local list = conform.list_formatters_to_run(bufnr)
              T("planned formatters: " ..
                vim.inspect(vim.tbl_map(function(f) return f.name end, list)))
              if opts.range > 0 then
                T("calling conform.format SYNC range")
                local ok, err = pcall(conform.format, {
                  bufnr = bufnr,
                  async = false,
                  timeout_ms = 5000,
                  lsp_format = "prefer",
                  range = {
                    ["start"] = { opts.line1, 0 },
                    ["end"]   = { opts.line2, 0 },
                  },
                })
                T("range result ok=" .. tostring(ok) .. " err=" .. tostring(err))
              else
                T("calling conform.format SYNC whole-buffer")
                local ok, err = pcall(conform.format, {
                  bufnr = bufnr,
                  async = false,
                  timeout_ms = 5000,
                  lsp_format = "prefer",
                })
                T("result ok=" .. tostring(ok) .. " err=" .. tostring(err))
              end
              if trace then trace:close() end
            end, { range = true, desc = "Format buffer (or range) via conform / LSP" })

            -- `:FormatProbe` — diagnostic dump for the
            -- conform → LSP routing. Prints which clients are
            -- attached, which conform considers eligible for
            -- format, and which formatters conform plans to run.
            -- Output goes to /tmp/conform-probe.log (and :messages).
            vim.api.nvim_create_user_command("FormatProbe", function()
              local lines = {}
              local function L(msg) table.insert(lines, msg) end
              local bufnr = vim.api.nvim_get_current_buf()
              L("buffer: " .. vim.api.nvim_buf_get_name(bufnr))
              L("filetype: " .. vim.bo[bufnr].filetype)
              L("--- vim.lsp.get_clients(bufnr) ---")
              for _, c in ipairs(vim.lsp.get_clients({ bufnr = bufnr })) do
                local fmt = c.server_capabilities
                  and c.server_capabilities.documentFormattingProvider
                L(string.format(
                  "  %s id=%d formatProvider=%s supports_method=%s",
                  c.name,
                  c.id,
                  vim.inspect(fmt),
                  tostring(c:supports_method("textDocument/formatting", { bufnr = bufnr }))
                ))
              end
              local lsp_fmt = require("conform.lsp_format")
              local fmt_clients = lsp_fmt.get_format_clients({ bufnr = bufnr })
              L("--- conform.lsp_format.get_format_clients ---")
              L("count: " .. tostring(#fmt_clients))
              for _, c in ipairs(fmt_clients) do
                L("  " .. c.name .. " id=" .. c.id)
              end
              local conform = require("conform")
              L("--- formatters_by_ft ---")
              L("[terraform] = " .. vim.inspect(conform.formatters_by_ft.terraform))
              L("[_]         = " .. vim.inspect(conform.formatters_by_ft._))
              local list = conform.list_formatters_to_run(bufnr)
              L("--- list_formatters_to_run ---")
              L(vim.inspect(vim.tbl_map(function(f) return f.name end, list)))
              local out = table.concat(lines, "\n")
              local fh = io.open("/tmp/conform-probe.log", "w")
              if fh then fh:write(out); fh:close() end
              vim.api.nvim_echo(
                vim.tbl_map(function(l) return { l, "Normal" } end,
                  vim.split(out, "\n", { plain = true })),
                false, {})
            end, { desc = "Dump conform/LSP routing state for the current buffer" })

            -- Neovim 0.12 compatibility: wrap add_predicate/add_directive so third-party
            -- plugin handlers automatically receive single TSNode instead of TSNode[] lists.
            -- This runs before plugins load, so all subsequent handler registrations are wrapped.
            do
              local ts_query = require("vim.treesitter.query")
              local orig_add_predicate = ts_query.add_predicate
              local orig_add_directive = ts_query.add_directive

              local function unwrap_match(match)
                local unwrapped = {}
                for k, v in pairs(match) do
                  unwrapped[k] = (type(v) == "table") and v[1] or v
                end
                return unwrapped
              end

              ts_query.add_predicate = function(name, handler, opts)
                local wrapped = function(match, ...)
                  return handler(unwrap_match(match), ...)
                end
                return orig_add_predicate(name, wrapped, opts)
              end

              ts_query.add_directive = function(name, handler, opts)
                local wrapped = function(match, ...)
                  return handler(unwrap_match(match), ...)
                end
                return orig_add_directive(name, wrapped, opts)
              end
            end

            -- Fix Snacks picker cursor jump: nvim_win_call from plugins (lualine etc.)
            -- briefly exits insert mode in prompt buftype. The prompt auto-re-enters
            -- insert without "!", leaving cursor 1 position back. Fix by wrapping
            -- nvim_win_call to restore insert mode at end of line when in picker input.
            do
              local orig_win_call = vim.api.nvim_win_call
              vim.api.nvim_win_call = function(win, fn)
                local cur_buf = vim.api.nvim_get_current_buf()
                local was_insert = vim.fn.mode():find("^i") ~= nil
                local is_picker = was_insert and vim.bo[cur_buf].buftype == "prompt"
                    and vim.bo[cur_buf].filetype == "snacks_picker_input"
                local saved_col
                if is_picker then
                  saved_col = vim.api.nvim_win_get_cursor(0)[2]
                end
                local result = orig_win_call(win, fn)
                if is_picker and not vim.fn.mode():find("^i") then
                  vim.cmd("startinsert!")
                elseif is_picker and vim.fn.mode():find("^i") then
                  local cur_col = vim.api.nvim_win_get_cursor(0)[2]
                  if cur_col < saved_col then
                    pcall(vim.api.nvim_win_set_cursor, 0, { 1, saved_col })
                  end
                end
                return result
              end
            end

            -- Fix twilight.nvim: get_parser returns nil in Neovim 0.12
            vim.api.nvim_create_autocmd("VimEnter", {
              once = true,
              callback = function()
                vim.schedule(function()
                  local ok, tw = pcall(require, "twilight.view")
                  if ok and tw then
                    local orig_get_node = tw.get_node
                    tw.get_node = function(buf, line)
                      local ok2, parser = pcall(vim.treesitter.get_parser, buf)
                      if not ok2 or not parser then return nil end
                      return orig_get_node(buf, line)
                    end
                  end
                end)
              end,
            })

            -- Silence otter-ls activation warning (vim.lsp.start returns nil in Neovim 0.12)
            vim.api.nvim_create_autocmd("VimEnter", {
              once = true,
              callback = function()
                vim.schedule(function()
                  local ok, otter = pcall(require, "otter.lsp")
                  if ok and otter and otter.start then
                    local orig_start = otter.start
                    otter.start = function(...)
                      local result = orig_start(...)
                      return result
                    end
                  end
                  -- Suppress the specific notify_once message
                  local orig_notify_once = vim.notify_once
                  vim.notify_once = function(msg, ...)
                    if type(msg) == "string" and msg:find("%[otter%] activation of otter%-ls failed") then
                      return
                    end
                    return orig_notify_once(msg, ...)
                  end
                end)
              end,
            })

            -- Fix kulala HTTP syntax highlighting: kulala registers kulala_http as the
            -- treesitter language for http filetype, but the highlighter was already started
            -- with the http language. Restart highlighting after kulala loads so it picks up
            -- the kulala_http queries.
            vim.api.nvim_create_autocmd("FileType", {
              pattern = { "http", "rest" },
              callback = function(ev)
                vim.defer_fn(function()
                  if not vim.api.nvim_buf_is_valid(ev.buf) then return end
                  local lang = vim.treesitter.language.get_lang("http")
                  if lang == "kulala_http" then
                    vim.treesitter.stop(ev.buf)
                    vim.treesitter.start(ev.buf, "kulala_http")
                  end
                end, 100)
              end,
            })

            -- Fix ts-context-commentstring: get_parser returns nil in Neovim 0.12
            -- (upstream fix: github.com/JoosepAlviste/nvim-ts-context-commentstring/commit/0e8937ba)
            vim.api.nvim_create_autocmd("VimEnter", {
              once = true,
              callback = function()
                vim.schedule(function()
                  local ok, utils = pcall(require, "ts_context_commentstring.utils")
                  if ok and utils then
                    utils.is_treesitter_active = function(bufnr)
                      bufnr = bufnr or 0
                      local ok2, parser = pcall(vim.treesitter.get_parser, bufnr)
                      return ok2 and parser ~= nil
                    end
                  end
                end)
              end,
            })

            -- Fix indent-tools: make_repeatable_move_pair was removed from
            -- nvim-treesitter-textobjects, replaced by make_repeatable_move
            do
              local ok, rm = pcall(require, "nvim-treesitter-textobjects.repeatable_move")
              if not ok then
                ok, rm = pcall(require, "nvim-treesitter.textobjects.repeatable_move")
              end
              if ok and rm and not rm.make_repeatable_move_pair and rm.make_repeatable_move then
                rm.make_repeatable_move_pair = function(forward_fn, backward_fn)
                  return rm.make_repeatable_move(forward_fn), rm.make_repeatable_move(backward_fn)
                end
              end
            end

            -- Suppress Neovim 0.12 deprecation warnings from plugins using old APIs
            -- vim.lsp.get_buffers_by_client_id (used by nvim-navbuddy)
            vim.lsp.get_buffers_by_client_id = function(client_id)
              local client = vim.lsp.get_client_by_id(client_id)
              if not client then return {} end
              return vim.tbl_keys(client.attached_buffers)
            end
            -- vim.validate old table syntax → new style (used by indent-tools.nvim)
            do
              local orig_validate = vim.validate
              vim.validate = function(first, ...)
                if type(first) == "table" and select("#", ...) == 0 then
                  for name, spec in pairs(first) do
                    orig_validate(name, spec[1], spec[2], spec[3])
                  end
                  return
                end
                return orig_validate(first, ...)
              end
            end

            -- Performance optimizations
            vim.g.loaded_node_provider = 0  -- Disable Node.js provider
            vim.g.loaded_perl_provider = 0  -- Disable Perl provider
            vim.g.loaded_ruby_provider = 0  -- Disable Ruby provider
            vim.opt.redrawtime = 1500        -- Faster redraw timeout

            -- Disable LSP logging entirely: server stderr (nixd IPC traces,
            -- terraform-ls job progress) is logged as [ERROR] regardless of its
            -- actual severity, making the log useless and growing it to gigabytes.
            -- Real LSP errors surface as diagnostics in the buffer, not in this file.
            vim.lsp.log.set_level("off")

            -- Prevent marksman from attaching to temp files (e.g. Claude Code prompt files
            -- in /private/tmp). marksman searches the parent dir for wiki-link backlinks and
            -- hits permission-denied Nix sandbox dirs, causing error spam and 2GB+ log files.
            vim.api.nvim_create_autocmd("LspAttach", {
              callback = function(args)
                local client = vim.lsp.get_client_by_id(args.data.client_id)
                if client and client.name == "marksman" then
                  local fname = vim.api.nvim_buf_get_name(args.buf)
                  if fname:match("^/tmp/") or fname:match("^/private/tmp/") then
                    vim.lsp.buf_detach_client(args.buf, args.data.client_id)
                  end
                end
              end,
            })

            -- Point terraform-ls at the project's terraform binary via direnv.
            -- Projects may use nix devshells (via direnv) to supply a specific terraform
            -- version; direnv may not have activated in Neovim's PATH yet when before_init
            -- runs. We pre-warm the path asynchronously (via jobstart) and fall back to
            -- exepath() in before_init so we never block the UI waiting for direnv.
            -- vim.lsp.config merges on repeated calls, so this adds before_init on top of the
            -- capabilities-only config emitted by NixVim's LSP module.

            -- Async cache of terraform binary paths keyed by project root directory.
            -- nil = not yet started, false = job pending, string = resolved path.
            local terraform_path_cache = {}

            local function prewarm_terraform_path(root)
              if terraform_path_cache[root] ~= nil then return end
              terraform_path_cache[root] = false  -- mark pending
              -- Prefer `terraform`; fall back to `tofu` for OpenTofu-only projects.
              vim.fn.jobstart(
                { "direnv", "exec", root, "sh", "-c", "which terraform 2>/dev/null || which tofu 2>/dev/null" },
                {
                  stdout_buffered = true,
                  stderr_buffered = true,
                  on_stdout = function(_, data)
                    local path = (data and data[1] or ""):gsub("%s+$", "")
                    if path ~= "" and vim.fn.executable(path) == 1 then
                      terraform_path_cache[root] = path
                    end
                  end,
                  on_exit = function()
                    -- If on_stdout didn't store a valid path, fall back to exepath
                    if terraform_path_cache[root] == false then
                      local path = vim.fn.exepath("terraform")
                      if path == "" then path = vim.fn.exepath("tofu") end
                      terraform_path_cache[root] = path
                    end
                  end,
                }
              )
            end

            -- Pre-warm the cache before the buffer is read so the path is likely
            -- resolved by the time terraformls fires before_init.
            vim.api.nvim_create_autocmd("BufReadPre", {
              pattern = { "*.tf", "*.tfvars", "*.hcl", "*.tofu" },
              callback = function()
                local file = vim.fn.expand("<afile>:p")
                local dir = vim.fn.fnamemodify(file, ":h")
                local root = vim.fn.getcwd()
                for _, marker in ipairs({ ".terraform", ".git", ".envrc" }) do
                  local found = vim.fn.finddir(marker, dir .. ";")
                  if found ~= "" then
                    root = vim.fn.fnamemodify(found, ":h")
                    break
                  end
                end
                prewarm_terraform_path(root)
              end,
            })

            vim.lsp.config("terraformls", {
              before_init = function(params, config)
                local root = config.root_dir or vim.fn.getcwd()
                -- Kick off async resolution (no-op if already started or cached)
                prewarm_terraform_path(root)
                -- Use cached path if ready; fall back to exepath without blocking.
                -- The direnv Neovim plugin updates PATH on DirChanged so exepath()
                -- usually already points to the correct direnv-managed terraform.
                local cached = terraform_path_cache[root]
                local terraform_path = (type(cached) == "string" and cached ~= "" and cached)
                  or vim.fn.exepath("terraform")
                if terraform_path ~= "" then
                  params.initializationOptions = params.initializationOptions or {}
                  params.initializationOptions.terraform = { path = terraform_path }
                end
              end,
            })

            -- Large file handling: disable expensive options before file is read.
            -- Uses vim.uv.fs_stat (reliable for files of any size, no -2 edge case).
            vim.api.nvim_create_autocmd("BufReadPre", {
              callback = function(ev)
                local file = vim.fn.expand("<afile>:p")
                local stat = vim.uv.fs_stat(file)
                if not stat or stat.type ~= "file" then return end
                local size = stat.size

                -- 10 MB+: disable disk-heavy features
                if size > 10 * 1024 * 1024 then
                  vim.opt_local.swapfile = false
                  vim.opt_local.undofile = false
                  vim.opt_local.backup = false
                  vim.opt_local.writebackup = false
                  vim.opt_local.foldmethod = "manual"
                  vim.opt_local.undolevels = -1
                end

                -- 100 MB+: suppress FileType and Syntax events during the read so no
                -- plugin processes the entire buffer before we can disable features.
                if size > 100 * 1024 * 1024 then
                  local saved_ei = vim.o.eventignore
                  vim.o.eventignore = saved_ei == "" and "FileType,Syntax"
                    or saved_ei .. ",FileType,Syntax"
                  vim.api.nvim_create_autocmd("BufReadPost", {
                    buffer = ev.buf,
                    once = true,
                    callback = function()
                      vim.o.eventignore = saved_ei
                      vim.bo[ev.buf].syntax = ""
                      vim.opt_local.foldmethod = "manual"
                      vim.opt_local.relativenumber = false
                      vim.opt_local.cursorline = false
                      vim.notify(
                        string.format(
                          "Large file (%.0f MB) — most features disabled",
                          size / 1024 / 1024
                        ),
                        vim.log.levels.WARN
                      )
                    end,
                  })
                end
              end,
            })

            -- :LspLogTail — open the last 2 MB of the LSP log in a scratch buffer.
            -- The full log can grow to several GB; this avoids loading the whole file.
            vim.api.nvim_create_user_command("LspLogTail", function()
              local log = vim.fn.stdpath("state") .. "/lsp.log"
              local stat = vim.uv.fs_stat(log)
              if not stat then
                vim.notify("LSP log not found: " .. log, vim.log.levels.WARN)
                return
              end
              vim.cmd("enew")
              vim.bo.buftype = "nofile"
              vim.bo.bufhidden = "wipe"
              vim.bo.swapfile = false
              pcall(vim.api.nvim_buf_set_name, 0, "lsp.log [tail]")
              local data = vim.fn.system("tail -c 2097152 " .. vim.fn.shellescape(log))
              local lines = vim.split(data, "\n", { plain = true })
              vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
              vim.bo.modified = false
              vim.bo.readonly = true
              vim.notify(
                string.format("LSP log (%.0f MB total) — showing last 2 MB", stat.size / 1024 / 1024),
                vim.log.levels.INFO
              )
            end, { desc = "Open tail of LSP log in scratch buffer" })

            -- :LspLogClear — truncate the LSP log file to zero bytes.
            vim.api.nvim_create_user_command("LspLogClear", function()
              local log = vim.fn.stdpath("state") .. "/lsp.log"
              local fd = vim.uv.fs_open(log, "w", 420)
              if fd then
                vim.uv.fs_close(fd)
                vim.notify("LSP log cleared: " .. log, vim.log.levels.INFO)
              else
                vim.notify("Failed to clear LSP log: " .. log, vim.log.levels.ERROR)
              end
            end, { desc = "Truncate the LSP log file to zero bytes" })

            -- Directory setup (sync - needed immediately)
            vim.o.backupdir = vim.fn.stdpath("data") .. "/backup"
            vim.o.directory = vim.fn.stdpath("data") .. "/directory"
            vim.o.sessionoptions = vim.o.sessionoptions .. ",globals"
            vim.o.undodir = vim.fn.stdpath("data") .. "/undo"
            vim.uv.fs_mkdir(vim.o.backupdir, 750)
            vim.uv.fs_mkdir(vim.o.directory, 750)
            vim.uv.fs_mkdir(vim.o.undodir, 750)

            -- Fix vim-tmux-navigator terminal mode keymaps: the plugin's default
            -- terminal mappings use <C-w>: to escape terminal mode before running
            -- the command, but this doesn't work in snacks.nvim terminals (used by
            -- Claude Code) and leaks command text into the terminal input. Override
            -- with <cmd> which works directly from terminal mode.
            vim.api.nvim_create_autocmd("VimEnter", {
              once = true,
              callback = function()
                vim.keymap.set("t", "<C-h>", "<cmd>TmuxNavigateLeft<CR>", { silent = true })
                vim.keymap.set("t", "<C-j>", "<cmd>TmuxNavigateDown<CR>", { silent = true })
                vim.keymap.set("t", "<C-k>", "<cmd>TmuxNavigateUp<CR>", { silent = true })
                vim.keymap.set("t", "<C-l>", "<cmd>TmuxNavigateRight<CR>", { silent = true })
              end,
            })

            -- Claude Code integration (WebSocket MCP protocol)
            require('claudecode').setup({
              terminal = {
                provider = "external",
                provider_opts = {
                  external_terminal_cmd = "tmux split-window -h -l 40%% '%s'",
                },
              },
            })

            -- Defer non-critical plugin setups to speed up startup
            vim.defer_fn(function()
              require('jj').setup({})
              require('pipeline').setup({})
            end, 50)

            -- Live-preview rename
            require("inc_rename").setup()

            -- Performance annotation (perf/flamegraph overlay)
            require('perfanno').setup({})

            -- Defer UpdateRemotePlugins to avoid blocking startup
            vim.defer_fn(function()
              if vim.fn.argc() == 0 then
                vim.cmd("silent! UpdateRemotePlugins")
              end
            end, 100)

            -- Reduce filesystem polling for better performance with AV
            vim.opt.swapfile = true  -- Keep swapfiles but reduce write frequency
            vim.opt.updatecount = 200  -- Write swap after 200 characters (default: 200)

            -- Batch directory scans to reduce AV overhead
            vim.opt.wildignore:append({
              "*.o", "*.obj", "*.dylib", "*.bin", "*.dll", "*.exe",
              "*/.git/*", "*/.svn/*", "*/.DS_Store", "*/node_modules/*",
              "*/venv/*", "*/__pycache__/*", "*.pyc",
              "*/.nix-profile/*", "*/.nix-defexpr/*",
              -- macOS-specific AV exclusions for search performance
              "*.app/*",                       -- macOS application bundles
              "*/.Spotlight-V100/*",           -- Spotlight metadata
              "*/.fseventsd/*",                -- FSEvents
              "*/.DocumentRevisions-V100/*",   -- Document versions
              "*/.TemporaryItems/*",           -- Temporary items
              "*/.Trashes/*",                  -- Trash directories
              "*/Library/Caches/*",            -- Cache directories
              "*/DerivedData/*",               -- Xcode derived data
              "*/.build/*",                    -- Swift/Xcode build artifacts
            })

            -- Pre-compute fortune/cowsay asynchronously so mini.starter header is non-blocking.
            -- On AV-scanned machines, io.popen() would stall Lua until Defender finishes
            -- scanning the fortune and cowsay nix-store binaries. Instead, kick the job off
            -- when mini.starter opens (FileType starter), store the result in a global, and
            -- refresh the starter buffer once the output arrives.
            -- Using {"sh", "-c", ...} avoids loading the user's full interactive shell
            -- (zsh + oh-my-zsh etc.) which can itself add 500ms+ of startup overhead.
            vim.g._fortune_result = nil
            vim.api.nvim_create_autocmd("User", {
              pattern = "MiniStarterOpened",
              once = true,
              callback = function()
                local starter_buf = vim.api.nvim_get_current_buf()
                vim.fn.jobstart({"sh", "-c", "fortune -s 2>/dev/null | cowsay 2>/dev/null"}, {
                  stdout_buffered = true,
                  on_stdout = function(_, data)
                    if data then
                      local lines = vim.tbl_filter(function(l) return l ~= "" end, data)
                      if #lines > 0 then
                        vim.g._fortune_result = table.concat(lines, "\n")
                      end
                    end
                  end,
                  on_exit = function()
                    vim.schedule(function()
                      if vim.api.nvim_buf_is_valid(starter_buf)
                        and vim.api.nvim_get_current_buf() == starter_buf
                      then
                        pcall(require("mini.starter").refresh)
                      end
                    end)
                  end,
                })
              end,
            })

            -- Custom async git commands that only show output on error
            -- This replaces Git! push, fetch, etc. with silent versions
            local function async_git_command(args, desc)
              local output = {}
              local stderr = {}

              vim.fn.jobstart(vim.list_extend({"git"}, args), {
                cwd = vim.fn.FugitiveGitDir() and vim.fn.FugitiveWorkTree() or vim.fn.getcwd(),
                stdout_buffered = true,
                stderr_buffered = true,
                on_stdout = function(_, data)
                  if data then
                    vim.list_extend(output, data)
                  end
                end,
                on_stderr = function(_, data)
                  if data then
                    vim.list_extend(stderr, data)
                  end
                end,
                on_exit = function(_, exit_code)
                  if exit_code == 0 then
                    vim.notify(desc .. " completed successfully", vim.log.levels.INFO)
                  else
                    -- Show error in a split
                    local all_output = vim.list_extend(vim.list_extend({}, output), stderr)
                    -- Filter out empty lines
                    all_output = vim.tbl_filter(function(line) return line ~= "" end, all_output)

                    if #all_output > 0 then
                      local buf = vim.api.nvim_create_buf(false, true)
                      vim.api.nvim_buf_set_lines(buf, 0, -1, false, all_output)
                      vim.bo[buf].filetype = "git"

                      vim.cmd("botright split")
                      vim.api.nvim_win_set_buf(0, buf)
                      vim.cmd("wincmd p")
                    end

                    vim.notify(desc .. " failed (exit code: " .. exit_code .. ")", vim.log.levels.ERROR)
                  end
                end,
              })
            end

            -- Create custom commands
            vim.api.nvim_create_user_command("GitPushSilent", function()
              async_git_command({"push"}, "Git push")
            end, {})

            vim.api.nvim_create_user_command("GitPushForceLeaseSilent", function()
              async_git_command({"push", "--force-with-lease"}, "Git push --force-with-lease")
            end, {})

            vim.api.nvim_create_user_command("GitPushTagsSilent", function()
              async_git_command({"push", "--tags"}, "Git push --tags")
            end, {})

            vim.api.nvim_create_user_command("GitFetchSilent", function(opts)
              local args = {"fetch"}
              if opts.args ~= "" then
                vim.list_extend(args, vim.split(opts.args, "%s+"))
              else
                vim.list_extend(args, {"origin", "--prune"})
              end
              async_git_command(args, "Git fetch")
            end, { nargs = "*" })

            -- Terraform/OpenTofu tools: docs lookup and security scanning
            require("terraform-tools").setup()
            require("terraform-search").setup()

            -- Peek.nvim setup
            require("peek").setup({})
            vim.api.nvim_create_user_command("PeekOpen", require("peek").open, {})
            vim.api.nvim_create_user_command("PeekClose", require("peek").close, {})
          '';

          extraFiles = {
            "ftplugin/http.lua".text = import ./ftplugin/http.lua.nix;
            "lua/terraform-search.lua".source = ./lua/terraform-search.lua;
            "lua/terraform-tools.lua".source = ./lua/terraform-tools.lua;
            # Patched Python highlights query without "except*" keyword
            # TODO: Remove once nvim-treesitter fixes the query upstream
            "queries/python/highlights.scm".source = ./queries/python/highlights.scm;
            # Patched gotmpl highlights: remove "else if" node type not in grammar
            "queries/gotmpl/highlights.scm".source = ./queries/gotmpl/highlights.scm;
            # Patched php_only highlights: remove "from" node type not in grammar
            "queries/php_only/highlights.scm".source = ./queries/php_only/highlights.scm;
          };

          extraPackages = with pkgs; [
            # alejandra
            # lldb
            (python3.withPackages (python-pkgs: [ python-pkgs.pylatexenc ]))
            black
            cowsay
            curl
            deno
            direnv
            fd
            fortune
            ghostscript
            gofumpt
            golangci-lint
            golines
            grpcurl
            imagemagick
            isort
            jq
            jujutsu
            lspmux
            lsof
            nixpkgs-fmt
            openssl
            prettier
            prettierd
            ripgrep
            shfmt
            sqlite
            stable.tectonic
            stylua
            terraform
            tfsec
            trivy
            websocat
            wordnet
          ];

          extraPlugins = with pkgs.vimPlugins; [
            blink-cmp-avante
            blink-cmp-conventional-commits
            blink-cmp-env
            blink-cmp-spell
            blink-emoji-nvim
            claudecode-nvim
            inc-rename-nvim
            peek-nvim
            perfanno-nvim
            vim-dadbod
            vim-dadbod-completion
            vim-dadbod-ui
            vim-pencil
            vim-table-mode

            (pkgs.vimUtils.buildVimPlugin {
              pname = "blink-cmp-dap";
              version = "0-unstable-2024-12-31";
              doCheck = false;
              src = pkgs.fetchFromGitHub {
                owner = "mayromr";
                repo = "blink-cmp-dap";
                rev = "772c51ff57025b0a02fcee31d1a3bd369ae370d5";
                hash = "sha256-iDoMOaxxCkwsn109PJehokUjYiIQESujC2fAyZeRIhc=";
              };
            })

            (pkgs.vimUtils.buildVimPlugin {
              pname = "blink-cmp-tmux";
              version = "0-unstable-2024-12-31";
              src = pkgs.fetchFromGitHub {
                owner = "mgalliou";
                repo = "blink-cmp-tmux";
                rev = "4586c705b6f80b536c34a61ed0d3cd4d7f08322d";
                hash = "sha256-99wmBgU7Yt6eIAXppJUOYQVuiFcX8q8pmk6rKv/d87Q=";
              };
            })

            (pkgs.vimUtils.buildVimPlugin {
              pname = "jj-nvim";
              version = "0-unstable-2024-12-31";
              src = pkgs.fetchFromGitHub {
                owner = "NicolasGB";
                repo = "jj.nvim";
                rev = "d8280091989d10fd95f1109194846b613d5c4bd0";
                hash = "sha256-7taOkKswx5LdAi3Gx8jKHNskR/bshhc8wc1KrC1DK8Y=";
              };
            })

            (pkgs.vimUtils.buildVimPlugin {
              pname = "pipeline-nvim";
              version = "0-unstable-2024-12-31";
              src = pkgs.fetchFromGitHub {
                owner = "topaxi";
                repo = "pipeline.nvim";
                rev = "d14a27ba7f25ecb72e28bb9844672de99b151eaa";
                hash = "sha256-Pl1HkXpnyAIVct3BjGtGTQf2M270Gq5wSh+KUKnL1Tk=";
              };
            })

            (pkgs.vimUtils.buildVimPlugin {
              pname = "vscode-terraform-doc-snippets";
              version = "0-unstable-2024-12-31";
              src = pkgs.fetchFromGitHub {
                owner = "run-at-scale";
                repo = "vscode-terraform-doc-snippets";
                rev = "6ab3e44b566e660f38922cf908e6e547eaa5d4b4";
                hash = "sha256-v392tyzXV+zyBNt5OCB2NBCK7JcByrTa5Ne/nFtSCJI=";
              };
            })
          ];

          extraPython3Packages = p: [
            p.ipykernel
            p.jupyter-client
            p.numpy
            # p.plotly
            p.pnglatex
            p.pynvim
            p.pyperclip
          ];

          globals = {
            localleader = ",";
            mapleader = " ";
            markdown_folding = true;
          };

          opts = {
            autoindent = true;
            backspace = "indent,eol,start";
            backup = true;
            cmdheight = 0; # Required when using Noice
            completeopt = "menu,menuone,noselect";
            conceallevel = 0;
            cursorline = true;
            expandtab = true;
            foldcolumn = "1";
            foldenable = true;
            foldlevel = 5;
            foldlevelstart = 99;
            ignorecase = true;
            laststatus = 3;
            mouse = "a";
            number = true;
            pumheight = 0;
            relativenumber = true;
            shiftwidth = 4;
            showtabline = 1;
            signcolumn = "yes";
            smartcase = true;
            tabstop = 4;
            termguicolors = true;
            timeoutlen = 300;
            undofile = true;
            updatetime = 300; # Restored to 300ms for better AV performance (was 50ms)
            wrap = false;
            writebackup = true;
            # Performance optimizations
            synmaxcol = 300; # Limit syntax highlighting columns
            lazyredraw = false; # Don't redraw during macros (keep false for smooth UI)
            regexpengine = 0; # Auto-select regex engine
            maxmempattern = 1000; # Limit memory for pattern matching
            # Search optimizations for AV-heavy environments (macOS Defender)
            hlsearch = false; # Disable search highlighting by default (use Telescope/Snacks instead)
            incsearch = true; # Keep incremental search enabled
            # Timeout settings
            timeout = true;
            ttimeout = true;
            ttimeoutlen = 50;
          };

          keymaps = [
            {
              mode = "n";
              key = "-";
              action = "<cmd>Oil<CR>";
              options = { desc = "Open parent directory"; silent = true; };
            }
          ]
          ++ import ./keymaps/ai/claudecode
          ++ import ./keymaps/ai/sidekick
          ++ import ./keymaps/buffers
          ++ import ./keymaps/db
          ++ import ./keymaps/debugging
          ++ import ./keymaps/folding
          ++ import ./keymaps/git
          ++ import ./keymaps/git/fugitive
          ++ import ./keymaps/harpoon
          ++ import ./keymaps/jujutsu
          ++ import ./keymaps/jumps
          ++ import ./keymaps/lsp
          ++ import ./keymaps/notifications
          ++ import ./keymaps/obsidian
          ++ import ./keymaps/profiling
          ++ import ./keymaps/rust-lsp
          ++ import ./keymaps/search
          ++ import ./keymaps/tabs
          ++ import ./keymaps/terraform
          ++ import ./keymaps/terminal
          ++ import ./keymaps/testing
          ++ import ./keymaps/toggles
          ++ import ./keymaps/zk;

          performance = {
            byteCompileLua = {
              enable = true;
              nvimRuntime = true;
              plugins = true;
            };

            combinePlugins = {
              enable = false;

              standalonePlugins = with pkgs.vimPlugins; [
                conform-nvim
                copilot-lua
                friendly-snippets
                image-nvim
                mini-nvim
                nvim-jdtls
                nvim-treesitter
                nvim-treesitter-parsers.http
                oil-nvim
                snacks-nvim
              ];
            };
          };

          plugins = {
            bacon.enable = true;
            cmp-dap.enable = true;
            comfy-line-numbers.enable = true;
            comment.enable = true;
            committia.enable = true;
            direnv.enable = true;
            earthly.enable = true;
            fidget.enable = true;
            friendly-snippets.enable = true;
            fugitive.enable = true;
            gitignore.enable = true;
            gitsigns.enable = true;
            hardtime.enable = false;
            helm.enable = true;
            helpview.enable = true;
            hmts.enable = true;
            lastplace.enable = true;
            lspkind.enable = true;
            lspsaga.enable = false;
            markdown-preview.enable = false; # Disabled due to memory constraints during nix build on macOS
            molten.enable = false;
            navic.enable = true;
            nix.enable = true;
            numbertoggle.enable = true;
            nvim-ufo.enable = true;
            rainbow-delimiters.enable = true;
            rhubarb.enable = true;
            roslyn.enable = false;
            sleuth.enable = true;
            smear-cursor.enable = true;
            specs.enable = false;
            startify.enable = false;
            tmux-navigator.enable = true;
            treesitter-textobjects.enable = true;
            ts-autotag.enable = true;
            ts-context-commentstring.enable = true;
            typst-vim.enable = true;
            vim-css-color.enable = true;
            web-devicons.enable = true;
            wilder.enable = false; # Conflicts with Noice
            wrapping.enable = true;
            zig.enable = true;
          }
          // (
            # // (import ./plugin-config/teamtype)
            # // (import ./plugin-config/tailwind-tools)
            (import ./plugin-config/auto-session)
            // (import ./plugin-config/arrow)
            // (import ./plugin-config/blink-cmp { inherit pkgs; })
            // (import ./plugin-config/blink-cmp-dictionary)
            // (import ./plugin-config/blink-cmp-git)
            // (import ./plugin-config/blink-compat)
            // (import ./plugin-config/blink-ripgrep)
            // (import ./plugin-config/ccc)
            // (import ./plugin-config/colorful-menu)
            // (import ./plugin-config/conform-nvim)
            // (import ./plugin-config/crates)
            // (import ./plugin-config/cybu)
            // (import ./plugin-config/dap { inherit pkgs; })
            // (import ./plugin-config/dap-go { inherit pkgs; })
            // (import ./plugin-config/dap-lldb { inherit pkgs; })
            // (import ./plugin-config/dap-python { inherit pkgs; })
            // (import ./plugin-config/dap-ui)
            // (import ./plugin-config/dap-virtual-text)
            // (import ./plugin-config/faster-nvim)
            // (import ./plugin-config/git-conflict)
            // (import ./plugin-config/harpoon)
            // (import ./plugin-config/image)
            // (import ./plugin-config/img-clip { inherit pkgs; })
            // (import ./plugin-config/indent-tools)
            // (import ./plugin-config/kulala { inherit pkgs; })
            // (import ./plugin-config/lazydev)
            // (import ./plugin-config/lsp {
              inherit pkgs lspWrappers;
              terraform-ls-rs = inputs.terraform-ls-rs.packages.${pkgs.stdenv.hostPlatform.system}.default;
            })
            // (import ./plugin-config/lspkind)
            // (import ./plugin-config/lualine)
            // (import ./plugin-config/luasnip)
            // (import ./plugin-config/lz-n)
            // (import ./plugin-config/mini)
            // (import ./plugin-config/modicator)
            // (import ./plugin-config/navbuddy)
            // (import ./plugin-config/neorg { inherit pkgs; })
            // (import ./plugin-config/neotest)
            // (import ./plugin-config/noice { inherit pkgs; })
            // (import ./plugin-config/none-ls)
            // (import ./plugin-config/obsidian)
            // (import ./plugin-config/octo)
            // (import ./plugin-config/oil)
            // (import ./plugin-config/oil-git-status)
            // (import ./plugin-config/origami)

            // (import ./plugin-config/otter)
            // (import ./plugin-config/parinfer-rust)
            // (import ./plugin-config/remote-nvim { inherit pkgs; })
            // (import ./plugin-config/render-markdown)
            // (import ./plugin-config/rustaceanvim { inherit pkgs; })
            // (import ./plugin-config/schema-companion)
            // (import ./plugin-config/schemastore)
            // (import ./plugin-config/sidekick)
            // (import ./plugin-config/smartcolumn)
            // (import ./plugin-config/snacks)
            // (import ./plugin-config/tardis)
            // (import ./plugin-config/tiny-devicons-auto-colors)
            // (import ./plugin-config/tiny-inline-diagnostic)
            // (import ./plugin-config/treesitter { inherit pkgs; })
            // (import ./plugin-config/treesitter-context)
            // (import ./plugin-config/trouble)
            // (import ./plugin-config/tv)
            // (import ./plugin-config/twilight)
            // (import ./plugin-config/vim-be-good)
            // (import ./plugin-config/which-key)
            // (import ./plugin-config/zen-mode)
            // (import ./plugin-config/zk)
          );
        } // (
          # (import ./colorschemes/ayu)
          # (import ./colorschemes/catppuccin)
          # (import ./colorschemes/everforest)
          # (import ./colorschemes/gruvbox)
          # (import ./colorschemes/kanagawa-paper)
          # (import ./colorschemes/melange)
          # (import ./colorschemes/modus)
          # (import ./colorschemes/monokai-pro)
          # (import ./colorschemes/nightfox)
          # (import ./colorschemes/rose-pine)
          # (import ./colorschemes/tokyonight)
          # (import ./colorschemes/vscode)
          # (import ./colorschemes/poimandres)
          # (import ./colorschemes/onedark)
          (import ./colorschemes/bamboo)
        );
    in
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "aarch64-darwin" "aarch64-linux" "x86_64-darwin" "x86_64-linux" ];

      imports = [ inputs.treefmt-nix.flakeModule ];

      perSystem =
        { pkgs
        , system
        , self
        , ...
        }:
        let
          nixvimLib = nixvim.lib.${system};
          nixvim' = nixvim.legacyPackages.${system};
          nvim = nixvim'.makeNixvimWithModule {
            inherit pkgs;
            module = config;
            extraSpecialArgs = { inherit lspWrappers; };
          };
          _module.args.pkgs = import self.inputs.nixpkgs {
            inherit system;
            config.allowUnfree = true;
          };

          # Shared LSP wrapper definitions — used by both nixvim config and
          # exported for external consumers (Claude Code, etc.)
          mkLspWrapper = scriptName: fullShellCmd:
            pkgs.writeShellScriptBin scriptName "exec ${fullShellCmd}";

          lspWrappers = {
            # Servers needing subcommands or flags to start in LSP mode:
            bash-language-server = mkLspWrapper "bash-language-server"
              "${pkgs.master.bash-language-server}/bin/bash-language-server start";
            vscode-css-language-server = mkLspWrapper "vscode-css-language-server"
              "${pkgs.vscode-langservers-extracted}/bin/vscode-css-language-server --stdio";
            docker-langserver = mkLspWrapper "docker-langserver"
              "${pkgs.dockerfile-language-server}/bin/docker-langserver --stdio";
            helm_ls = mkLspWrapper "helm_ls"
              "${pkgs.helm-ls}/bin/helm_ls serve";
            vscode-html-language-server = mkLspWrapper "vscode-html-language-server"
              "${pkgs.vscode-langservers-extracted}/bin/vscode-html-language-server --stdio";
            vscode-json-language-server = mkLspWrapper "vscode-json-language-server"
              "${pkgs.vscode-langservers-extracted}/bin/vscode-json-language-server --stdio";
            omnisharp-roslyn = mkLspWrapper "omnisharp"
              "${pkgs.omnisharp-roslyn}/bin/OmniSharp --languageserver";
            powershell-editor-services = pkgs.writeShellScriptBin "powershell-editor-services" ''
              CACHE_DIR="''${XDG_CACHE_HOME:-$HOME/.cache}/nvim"
              mkdir -p "$CACHE_DIR"
              BUNDLE="${pkgs.powershell-editor-services}/lib/powershell-editor-services"
              exec ${pkgs.powershell}/bin/pwsh -NoLogo -NoProfile -Command \
                "& '$BUNDLE/PowerShellEditorServices/Start-EditorServices.ps1' \
                  -BundledModulesPath '$BUNDLE' \
                  -LogPath '$CACHE_DIR/powershell_es.log' \
                  -SessionDetailsPath '$CACHE_DIR/powershell_es.session.json' \
                  -FeatureFlags @() \
                  -AdditionalModules @() \
                  -HostName nvim \
                  -HostProfileId 0 \
                  -HostVersion 1.0.0 \
                  -Stdio \
                  -LogLevel Normal"
            '';
            superhtml-lsp = mkLspWrapper "superhtml-lsp"
              "${pkgs.superhtml}/bin/superhtml lsp";
            tailwindcss-language-server = mkLspWrapper "tailwindcss-language-server"
              "${pkgs.tailwindcss-language-server}/bin/tailwindcss-language-server --stdio";
            taplo-lsp = mkLspWrapper "taplo-lsp"
              "${pkgs.taplo}/bin/taplo lsp stdio";
            terraform-ls = mkLspWrapper "terraform-ls"
              "${pkgs.terraform-ls}/bin/terraform-ls serve";
            tilt-lsp = mkLspWrapper "tilt-lsp"
              "${pkgs.tilt}/bin/tilt lsp server";
            typescript-language-server = mkLspWrapper "typescript-language-server"
              "${pkgs.typescript-language-server}/bin/typescript-language-server --stdio";
            vacuum-lsp = mkLspWrapper "vacuum-lsp"
              "${pkgs.vacuum-go}/bin/vacuum language-server";
            veryl-lsp = mkLspWrapper "veryl-lsp"
              "${pkgs.veryl}/bin/veryl lsp";
            yaml-language-server = mkLspWrapper "yaml-language-server"
              "${pkgs.master.yaml-language-server}/bin/yaml-language-server --stdio";
            marksman = mkLspWrapper "marksman"
              "${pkgs.stable.marksman}/bin/marksman server";

            # Servers that don't need wrappers (no special args):
            asm-lsp = pkgs.asm-lsp;
            clangd = pkgs.clang-tools;
            earthlyls = pkgs.earthlyls;
            emmet-ls = pkgs.emmet-ls;
            fortls = pkgs.fortls;
            golangci-lint-langserver = pkgs.golangci-lint-langserver;
            gopls = pkgs.gopls;
            lua-language-server = pkgs.lua-language-server;
            nixd = pkgs.nixd;
            pylsp = pkgs.python3Packages.python-lsp-server;
            rust-analyzer = pkgs.rust-analyzer;
            systemd-language-server = pkgs.systemd-language-server;

            # Faster alternatives exported for external consumers (e.g. Claude Code).
            # Not used by the nixvim config itself — kept here so both editors
            # can share the same binaries if desired.
            pyright = mkLspWrapper "pyright-langserver"
              "${pkgs.pyright}/bin/pyright-langserver --stdio";
            # tfls needs `tofu` (or `terraform`) on PATH to fetch provider
            # schemas for attribute hover. Wrap so external consumers like
            # Claude Code get a working schema fetch without relying on the
            # parent process's environment.
            tfls = pkgs.writeShellScriptBin "tfls" ''
              export PATH="${pkgs.opentofu}/bin:$PATH"
              exec ${inputs.terraform-ls-rs.packages.${system}.default}/bin/tfls "$@"
            '';
            vtsls = mkLspWrapper "vtsls"
              "${pkgs.vtsls}/bin/vtsls --stdio";
          } // pkgs.lib.optionalAttrs (!pkgs.stdenv.hostPlatform.isDarwin) {
            # nushell fails to compile on macOS (sandbox test failures), so
            # exclude nu-lsp from the wrapper set entirely on Darwin.
            nu-lsp = mkLspWrapper "nu-lsp"
              "${pkgs.nushell}/bin/nu --lsp";
          };
        in
        {
          _module.args.pkgs = import inputs.nixpkgs {
            inherit system;

            config = {
              allowUnfree = true;
            };

            overlays = [
              (final: _prev: {
                master = import inputs.nixpkgs-master {
                  system = final.stdenv.hostPlatform.system;
                  config.allowUnfree = true;
                };
              })
              # Pin claude-code to nixpkgs-master — nixos-unstable lags behind
              # and yanked versions cause build failures
              (final: _prev: {
                inherit (final.master) claude-code claude-code-bin;
              })
              (final: _prev: {
                stable = import inputs.nixpkgs-stable {
                  system = final.stdenv.hostPlatform.system;
                  config.allowUnfree = true;
                };
              })
              (final: _prev: {
                lspmux = final.rustPlatform.buildRustPackage {
                  pname = "lspmux";
                  version = "0.3.0";
                  src = final.fetchCrate {
                    pname = "lspmux";
                    version = "0.3.0";
                    hash = "sha256-+hnYb/ue8DVPtoNkIawlrVI2og6Wym09fRagZOUkVgY=";
                  };
                  # LSP compatibility fixes:
                  # 1. Accept `workspaceFolders: null` (per LSP spec). Claude
                  #    Code sends null when no workspace is set, causing lspmux
                  #    to reject the connection otherwise.
                  # 2. Skip pre-initialize notifications in the handshake.
                  #    lua-language-server sends `$/hello` and `window/logMessage`
                  #    before its initialize response.
                  # 3. Forward error responses from the client back to the
                  #    server. Some clients return an error for methods they
                  #    don't support, and the server needs to see that.
                  # 4. Auto-respond to `workspace/configuration` requests with
                  #    null values. Many clients (e.g. Claude Code) don't
                  #    implement this server→client request at all, causing
                  #    servers like taplo to hang indefinitely. Responding
                  #    with null is spec-compliant and unblocks the server.
                  patches = [
                    ./patches/lspmux-lsp-compat.patch
                    # 5. Cache `textDocument/publishDiagnostics`
                    #    notifications per URI and replay them to
                    #    every newly-attaching client. Without this,
                    #    a second nvim instance attaching to a
                    #    long-lived server only ever sees diagnostics
                    #    for files it explicitly re-opens — every
                    #    other URI's diagnostics were broadcast
                    #    before the new client existed.
                    ./patches/lspmux-cache-diagnostics.patch
                  ];
                  cargoHash = "sha256-Um4BZ1QTHCilOslo/GR7cGvPCX1xNitf6WU8QaehAaE=";
                  meta.mainProgram = "lspmux";
                };
              })
              (final: prev: {
                vimPlugins = prev.vimPlugins // {
                  # Pin nvim-treesitter from master for Neovim 0.12 ABI 15 compatible queries
                  inherit (final.master.vimPlugins) nvim-treesitter;

                  # Patch cybu.nvim for Neovim 0.12 deprecated vim.validate API
                  cybu-nvim = prev.vimPlugins.cybu-nvim.overrideAttrs (_: {
                    postPatch = ''
                      substituteInPlace lua/cybu/init.lua \
                        --replace-fail 'vim.validate({ user_config = { user_config, "table", true } })' \
                          'vim.validate("user_config", user_config, "table", true)' \
                        --replace-fail 'vim.validate({ direction = { direction, "string", false } })' \
                          'vim.validate("direction", direction, "string", false)'
                    '';
                  });
                  # Patch git-conflict.nvim for Neovim 0.12 deprecated API fixes
                  git-conflict-nvim = prev.vimPlugins.git-conflict-nvim.overrideAttrs (_: {
                    postPatch = ''
                      substituteInPlace lua/git-conflict.lua \
                        --replace-fail 'vim.highlight.priorities.user' 'vim.hl.priorities.user'
                      substituteInPlace lua/git-conflict/colors.lua \
                        --replace-fail "vim.validate({ rgb_24bit = { rgb_24bit, 'n', true } })" \
                          "vim.validate('rgb_24bit', rgb_24bit, 'number', true)"
                    '';
                  });
                  # Patch wrapping.nvim for Neovim 0.12 deprecated vim.validate API
                  wrapping-nvim = prev.vimPlugins.wrapping-nvim.overrideAttrs (_: {
                    postPatch = ''
                      ${final.python3}/bin/python3 -c "
import re, pathlib
p = pathlib.Path('lua/wrapping/init.lua')
src = p.read_text()
# Replace old-style vim.validate({...}) with individual vim.validate() calls
old = re.search(r'vim\.validate\(\{.*?\}\)', src, re.DOTALL).group(0)
# Extract field entries from the old validate call
entries = re.findall(r'(\w+)\s*=\s*\{\s*opts\.(\w+),\s*\"(\w+)\"\s*\}', old)
new_lines = []
for name, field, typ in entries:
    new_lines.append(f'    vim.validate(\"{name}\", opts.{field}, \"{typ}\")')
p.write_text(src.replace(old, '\n'.join(new_lines)))
"
                    '';
                  });

                  # avante-nvim = prev.vimPlugins.avante-nvim.overrideAttrs (oldAttrs: {
                  #   src = pkgs.fetchFromGitHub {
                  #     owner = "yetone";
                  #     repo = "avante.nvim";
                  #     rev = "4390828e88c8526649d1af7000df5c512fa49bbb";
                  #     hash = "sha256-asNRx4dhtzWVK6M2vWqATQtcHzrVQKvGQaqyVGSlunw=";
                  #   };
                  # });
                  # Override lualine to fetch directly from GitHub, bypassing luarocks hash issue
                  lualine-nvim = final.vimUtils.buildVimPlugin {
                    pname = "lualine.nvim";
                    version = "2024-11-12";
                    src = final.fetchFromGitHub {
                      owner = "nvim-lualine";
                      repo = "lualine.nvim";
                      rev = "0a5a66803c7407767b799067986b4dc3036e1983";
                      hash = "sha256-WcH2dWdRDgMkwBQhcgT+Z/ArMdm+VbRhmQftx4t2kNI=";
                    };
                  };
                  # Override bamboo to fetch directly from GitHub, avoiding lualine dependency issues
                  bamboo-nvim = final.vimUtils.buildVimPlugin rec {
                    pname = "bamboo.nvim";
                    version = "2024-11-25";
                    src = final.fetchFromGitHub {
                      owner = "ribru17";
                      repo = "bamboo.nvim";
                      rev = "1309bc88bffcf1bedc3e84e7fa9004de93da774a";
                      hash = "sha256-X9KrQg8TlhWGeeg2Loxv4OUBw/3Wt7XFVorDd/75CwA=";
                    };
                    # Skip require checks - some modules have optional lualine integration
                    doCheck = false;
                    doInstallCheck = false;
                    nvimRequireCheck = "";
                  };
                };
              })
            ];
          };

          checks = {
            default = nixvimLib.check.mkTestDerivationFromNvim {
              inherit nvim;
              name = "A nixvim configuration";
            };
          };

          packages = {
            default = nvim;
            nvim = nvim;
            lspmux = pkgs.lspmux;
          };

          # Export LSP wrappers for external consumers (Claude Code, etc.)
          legacyPackages.lspWrappers = lspWrappers;

          treefmt = {
            projectRootFile = "flake.nix";
            programs.nixpkgs-fmt.enable = true;
          };

          devShells = {
            default = pkgs.mkShell {
              buildInputs = with pkgs; [
                just
                nix-fast-build
              ];

              shellHook = ''
              '';
            };
          };
        };
    };
}
