-- lspmux.lua
--
-- Two user commands for managing the lspmux daemon that fronts every
-- shared language server in this Neovim configuration:
--
--   :LspmuxInfo     — version + uptime + per-server connections
--   :LspmuxRestart  — stop attached LSPs, kill the daemon, start a
--                     fresh one, and re-attach buffers so they
--                     pick up the new binary
--
-- Useful when iterating on language-server changes built via the
-- flake — bump the input, rebuild, then `:LspmuxRestart` instead of
-- `:qa` + relaunch nvim.
--
-- Setup:
--   require("lspmux").setup({ binary = "/path/to/lspmux" })
-- The `binary` option is optional; defaults to `vim.fn.exepath("lspmux")`.

local M = {}

local config = {
  binary = nil, -- resolved at setup
}

local function lspmux_bin()
  if config.binary and config.binary ~= "" then
    return config.binary
  end
  return vim.fn.exepath("lspmux")
end

local function run_capture(cmd)
  local out = vim.fn.system(cmd)
  if vim.v.shell_error ~= 0 then
    return nil, out
  end
  return out, nil
end

--- Run `pgrep -f` and return PID list (numbers) for `pattern`.
--- pgrep is BSD/macOS-friendly; same flag on Linux.
local function pgrep_pids(pattern)
  local out = vim.fn.systemlist({ "pgrep", "-f", pattern })
  if vim.v.shell_error ~= 0 then
    return {}
  end
  local pids = {}
  for _, line in ipairs(out) do
    local n = tonumber(vim.trim(line))
    if n then
      table.insert(pids, n)
    end
  end
  return pids
end

--- Read the server PID(s) — one server is the canonical case but if
--- multiple exist (e.g. a stale leak) we want to surface them all.
local function server_pids()
  return pgrep_pids("lspmux server")
end

--- Return seconds since the given PID started, or `nil` if `ps`
--- couldn't read the process. Uses `etimes` so we get a numeric
--- value rather than the human-formatted column.
local function process_uptime_seconds(pid)
  local out = vim.fn.system({
    "ps",
    "-o",
    "etime=",
    "-p",
    tostring(pid),
  })
  if vim.v.shell_error ~= 0 then
    return nil
  end
  -- ps -o etime gives "[[DD-]HH:]MM:SS" — parse to seconds.
  local s = vim.trim(out)
  if s == "" then
    return nil
  end
  local days, hours, mins, secs = 0, 0, 0, 0
  -- Try DD-HH:MM:SS
  local d, h, m, sec = s:match("^(%d+)-(%d+):(%d+):(%d+)$")
  if d then
    days, hours, mins, secs = tonumber(d), tonumber(h), tonumber(m), tonumber(sec)
  else
    -- HH:MM:SS
    local hh, mm, ss = s:match("^(%d+):(%d+):(%d+)$")
    if hh then
      hours, mins, secs = tonumber(hh), tonumber(mm), tonumber(ss)
    else
      -- MM:SS
      local mmm, sss = s:match("^(%d+):(%d+)$")
      if mmm then
        mins, secs = tonumber(mmm), tonumber(sss)
      else
        return nil
      end
    end
  end
  return days * 86400 + hours * 3600 + mins * 60 + secs
end

local function format_uptime(seconds)
  if not seconds then
    return "unknown"
  end
  if seconds < 60 then
    return string.format("%ds", seconds)
  end
  if seconds < 3600 then
    return string.format("%dm %ds", math.floor(seconds / 60), seconds % 60)
  end
  if seconds < 86400 then
    local h = math.floor(seconds / 3600)
    local m = math.floor((seconds % 3600) / 60)
    return string.format("%dh %dm", h, m)
  end
  local d = math.floor(seconds / 86400)
  local h = math.floor((seconds % 86400) / 3600)
  return string.format("%dd %dh", d, h)
end

--- Decode `lspmux status --json` into a Lua table. Returns
--- `{ instances = {...} }` on success; `nil, err` on failure.
local function load_status()
  local bin = lspmux_bin()
  if bin == "" then
    return nil, "lspmux binary not found in $PATH"
  end
  local out, err = run_capture({ bin, "status", "--json" })
  if not out then
    return nil, err or "lspmux status failed"
  end
  -- The status command writes a config-load INFO line on stderr
  -- that gets folded into stdout under `vim.fn.system`; strip
  -- everything before the first `{` so JSON parses cleanly.
  local brace = out:find("{")
  if brace then
    out = out:sub(brace)
  end
  local ok, decoded = pcall(vim.json.decode, out)
  if not ok then
    return nil, "could not parse lspmux status JSON: " .. tostring(decoded)
  end
  return decoded, nil
end

--- Format the InfoReport into lines for a scratch buffer.
local function build_info_lines()
  local lines = {}
  local function push(s)
    table.insert(lines, s)
  end

  push("# lspmux info")
  push("")

  -- Version.
  local bin = lspmux_bin()
  if bin == "" then
    push("status: lspmux binary NOT FOUND in $PATH")
    push("(set up the plugin with require(\"lspmux\").setup({ binary = '...' }))")
    return lines
  end
  push("binary: " .. bin)
  local ver = vim.fn.systemlist({ bin, "--version" })
  if vim.v.shell_error == 0 and ver[1] then
    push("version: " .. ver[1])
  else
    push("version: <error>")
  end

  -- Server PIDs + uptime.
  local pids = server_pids()
  if #pids == 0 then
    push("server: NOT RUNNING")
    push("")
    push("(use :LspmuxRestart to spawn one)")
    return lines
  end
  for _, pid in ipairs(pids) do
    local up = process_uptime_seconds(pid)
    push(string.format("server: pid %d, uptime %s", pid, format_uptime(up)))
  end

  -- Connected language-server instances + their clients.
  local status, err = load_status()
  if not status then
    push("")
    push("status: " .. (err or "<unknown>"))
    return lines
  end
  local instances = status.instances or {}
  push("")
  push(string.format("instances: %d", #instances))
  if #instances == 0 then
    push("  (no language servers attached)")
    return lines
  end
  for _, inst in ipairs(instances) do
    -- The exact JSON shape is set by lspmux's `print_status` —
    -- handle a few likely field names defensively. We display
    -- whichever of `name` / `server_path` / `command` shows up.
    local name = inst.name
      or inst.server_name
      or inst.server_path
      or inst.command
      or "<unknown>"
    local clients = inst.clients
      or inst.client_count
      or (inst.connections and #inst.connections)
      or "?"
    local line = string.format("  - %s — %s client(s)", name, tostring(clients))
    if inst.pid then
      line = line .. string.format(" [pid %d]", inst.pid)
    end
    push(line)
    -- Per-client detail when available (workspace path, pid, etc.).
    if type(inst.connections) == "table" then
      for _, c in ipairs(inst.connections) do
        local desc = c.workspace or c.cwd or c.client or "<connection>"
        push("      · " .. tostring(desc))
      end
    end
  end

  return lines
end

--- :LspmuxInfo — open a read-only scratch buffer with the info dump.
function M.info()
  local lines = build_info_lines()
  vim.cmd("enew")
  vim.bo.buftype = "nofile"
  vim.bo.bufhidden = "wipe"
  vim.bo.swapfile = false
  vim.bo.filetype = "markdown"
  pcall(vim.api.nvim_buf_set_name, 0, "lspmux info")
  vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
  vim.bo.modified = false
  vim.bo.readonly = true
end

--- True when the daemon's status RPC is responding — the canonical
--- "server is ready to accept clients" signal. Returns false on any
--- error (binary missing, exit non-zero, JSON unparseable).
local function daemon_ready()
  local bin = lspmux_bin()
  if bin == "" then
    return false
  end
  local out = vim.fn.system({ bin, "status", "--json" })
  if vim.v.shell_error ~= 0 then
    return false
  end
  local brace = out:find("{")
  if not brace then
    return false
  end
  local ok = pcall(vim.json.decode, out:sub(brace))
  return ok
end

--- Re-fire `FileType` autocmds across every loaded buffer so the
--- config's LSP attach hooks (lspconfig, `vim.lsp.config`, etc.)
--- create a fresh client connected to the just-started daemon.
--- Cleaner than `:edit` — no disk re-read, doesn't fight modeline
--- state, doesn't fire BufWritePre / BufLeave noise.
local function reattach_buffers()
  local count = 0
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buftype == "" then
      local ft = vim.bo[buf].filetype
      if ft and ft ~= "" then
        pcall(vim.api.nvim_exec_autocmds, "FileType", {
          buffer = buf,
          modeline = false,
        })
        count = count + 1
      end
    end
  end
  return count
end

--- :LspmuxRestart — stop nvim's LSP clients, kill the daemon, start
--- a fresh one, poll for it to be ready, then re-trigger LSP attach
--- on every buffer.
function M.restart()
  local bin = lspmux_bin()
  if bin == "" then
    vim.notify("lspmux binary not found in $PATH", vim.log.levels.ERROR)
    return
  end

  -- 1. Stop nvim's LSP clients gracefully so their own `lspmux client`
  --    subprocesses exit cleanly. force=true on the second arg
  --    sends SIGKILL after the graceful shutdown timer elapses.
  local clients = vim.lsp.get_clients()
  for _, c in ipairs(clients) do
    pcall(vim.lsp.stop_client, c.id, true)
  end

  -- 2. Kill any lingering `lspmux client` subprocesses started by
  --    nvim — vim.lsp.stop_client takes care of these, but a
  --    misbehaving / orphaned client wouldn't be stopped above.
  for _, pid in ipairs(pgrep_pids("lspmux client")) do
    pcall(vim.uv.kill, pid, "sigterm")
  end

  -- 3. Kill the server. SIGTERM first (graceful), then SIGKILL via
  --    the deferred straggler sweep below.
  for _, pid in ipairs(server_pids()) do
    pcall(vim.uv.kill, pid, "sigterm")
  end

  vim.defer_fn(function()
    -- 4. Force-kill any stragglers from steps 1–3.
    for _, pid in ipairs(server_pids()) do
      pcall(vim.uv.kill, pid, "sigkill")
    end
    for _, pid in ipairs(pgrep_pids("lspmux client")) do
      pcall(vim.uv.kill, pid, "sigkill")
    end

    -- 5. Spawn the new server detached so it survives if nvim exits.
    vim.fn.jobstart({ bin, "server" }, { detach = true })

    -- 6. Poll for the daemon to bind its socket. Up to ~3s
    --    (30 × 100ms). Without polling, an empty workspace's
    --    daemon-cold-start (~150-300ms typical) raced past our
    --    fixed delay and the FileType retrigger fired before any
    --    `lspmux client` could connect — so LSPs failed to
    --    attach silently and the user saw nothing happen.
    local function poll(attempts_left)
      if daemon_ready() then
        local n = reattach_buffers()
        vim.notify(
          string.format("lspmux restarted — %d buffer(s) reattached", n),
          vim.log.levels.INFO
        )
        return
      end
      if attempts_left <= 0 then
        vim.notify(
          "lspmux restart: daemon didn't come up — check :LspmuxInfo",
          vim.log.levels.ERROR
        )
        return
      end
      vim.defer_fn(function()
        poll(attempts_left - 1)
      end, 100)
    end
    poll(30)
  end, 200)
end

--- Optional configuration entry point. The :LspmuxInfo and
--- :LspmuxRestart commands register automatically from
--- `plugin/lspmux.lua` when the plugin is loaded — calling
--- `setup()` is only needed when overriding the binary path
--- (e.g. pinning the Nix store path so PATH lookup is bypassed).
function M.setup(opts)
  opts = opts or {}
  if opts.binary then
    config.binary = opts.binary
  end
end

return M
