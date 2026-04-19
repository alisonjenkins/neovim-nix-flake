-- terraform-search.lua
--
-- Search Terraform provider docs by *intent* — matches on descriptions,
-- not just prefixes on resource names. Backed by the custom LSP methods
-- `terraform-ls/searchDocs` and `terraform-ls/getDoc` exposed by
-- terraform-ls-rs. Works across every provider the server knows about;
-- no hardcoded provider list.
--
-- Entry points:
--   :TerraformSearch           -- prompt for query then show picker
--   :TerraformSearch <query>   -- skip the prompt
--
-- Inside the picker:
--   <CR>          smart-insert the resource *below* the enclosing block (or at
--                 the cursor if already at top level), with LSP snippet tabstops
--   <C-x> / <S-CR>  same, but insert *above* the enclosing block.
--                 `<S-CR>` only works in terminals that forward the sequence
--                 distinctly from `<CR>` (kitty keyboard / CSI-u); `<C-x>`
--                 is the reliable fallback and works everywhere.
--   <C-g>         open full markdown docs in a floating scratch buffer
--   <C-y>         yank the resource name
--
-- Inside the docs float:
--   q / <Esc>  close the float and return to the picker (state preserved)

local M = {}

local METHOD_SEARCH = "terraform-ls/searchDocs"
local METHOD_GET = "terraform-ls/getDoc"
local METHOD_SNIPPET = "terraform-ls/getSnippet"
local DEFAULT_LIMIT = 200

--- Locate an attached terraformls LSP client that advertises the
--- searchDocs experimental capability. Returns `nil, reason` on failure
--- so the caller can surface a useful message.
function M.find_client()
  local clients = vim.lsp.get_clients({ name = "terraformls" })
  if #clients == 0 then
    return nil, "no terraformls client attached — open a .tf file first"
  end
  for _, c in ipairs(clients) do
    local exp = (c.server_capabilities or {}).experimental or {}
    local tfls = (exp["terraform-ls"] or exp.terraform_ls)
    if tfls and tfls.searchDocs then
      return c
    end
  end
  return nil,
    "terraformls is attached but does not advertise terraform-ls/searchDocs"
    .. " — upgrade terraform-ls-rs"
end

--- Send a request to a specific LSP client and invoke `callback(err, result)`.
local function request(client, method, params, callback)
  client:request(method, params, function(err, result)
    callback(err, result)
  end, 0)
end

--- Run the searchDocs request and call `callback(items)`.
--- @param client any terraformls LSP client handle
--- @param query string
--- @param callback fun(items: table[])
function M.search(client, query, callback)
  local params = { query = query, limit = DEFAULT_LIMIT }
  request(client, METHOD_SEARCH, params, function(err, result)
    if err then
      vim.notify("searchDocs failed: " .. tostring(err.message or err),
        vim.log.levels.ERROR)
      callback({})
      return
    end
    callback((result and result.items) or {})
  end)
end

--- Fetch full markdown for a single item, then invoke `callback(markdown, url)`.
--- @param client any terraformls LSP client handle
--- @param name string
--- @param kind string "resource" | "data"
--- @param callback fun(markdown: string, url: string|nil)
function M.get_doc(client, name, kind, callback)
  local params = { name = name, kind = kind }
  request(client, METHOD_GET, params, function(err, result)
    if err or not result then
      callback("_failed to fetch docs: " .. tostring(err and err.message or "unknown") .. "_", nil)
      return
    end
    callback(result.markdown or "", result.registry_url)
  end)
end

--- Fetch an LSP snippet-format scaffold for `(name, kind)`, then invoke
--- `callback(snippet)`. `snippet` is nil if the server doesn't advertise
--- the capability or the request fails, so callers can fall back.
--- @param client any terraformls LSP client handle
--- @param name string
--- @param kind string "resource" | "data"
--- @param callback fun(snippet: string|nil)
function M.get_snippet(client, name, kind, callback)
  local exp = (client.server_capabilities or {}).experimental or {}
  local tfls = exp["terraform-ls"] or exp.terraform_ls or {}
  if not tfls.getSnippet then
    callback(nil)
    return
  end
  local params = { name = name, kind = kind }
  request(client, METHOD_SNIPPET, params, function(err, result)
    if err or not result or not result.snippet then
      callback(nil)
      return
    end
    callback(result.snippet)
  end)
end

--- Find a safe 0-based row for `nvim_buf_set_lines` to insert the new
--- resource block at.
---
--- Walks up from the cursor's syntax node and keeps the outermost `block`
--- ancestor (closest to the tree root). Works regardless of any
--- intermediate `body` / `config_file` wrapping in the grammar.
---
--- Returns `(row_0based, relocated)`:
--- * `row_0based`: the position to pass to `set_lines`.
--- * `relocated`: `true` if we actually moved the insert point out of
---   an enclosing block (caller can use this to add a visual gap).
---
--- Fallbacks when treesitter / the parser / a block ancestor are absent:
--- * "below" — insert immediately below the cursor (same as old behavior)
--- * "above" — insert at the cursor row, pushing the cursor line down
---
--- @param buf integer
--- @param row integer 1-based cursor row
--- @param direction string "above" or "below"
--- @return integer row_0based
--- @return boolean relocated
local function find_safe_insert_row(buf, row, direction)
  local fallback = direction == "above" and (row - 1) or row

  if not vim.treesitter then return fallback, false end
  local ok_parser, parser = pcall(vim.treesitter.get_parser, buf)
  if not ok_parser or not parser then return fallback, false end
  local trees = parser:parse()
  if not trees or not trees[1] then return fallback, false end
  local root = trees[1]:root()
  if not root then return fallback, false end

  local target_row = row - 1 -- 0-based
  local node = root:named_descendant_for_range(target_row, 0, target_row, 0)
  if not node then return fallback, false end

  local top_block = nil
  while node do
    if node:type() == "block" then
      top_block = node
    end
    node = node:parent()
  end
  if not top_block then return fallback, false end

  local sr, _, er, _ = top_block:range()
  if direction == "above" then
    return sr, true
  end
  return er + 1, true
end

--- Smart-insert a resource/data block at a safe location. Uses the LSP
--- snippet (with tabstops for required attributes) when the server has
--- the getSnippet capability; falls back to a naked skeleton otherwise.
--- @param win integer Originating window handle
--- @param client any terraformls LSP client handle
--- @param item table Picker item with {name, kind}
--- @param direction string "above" or "below" (default "below")
local function smart_insert(win, client, item, direction)
  direction = direction or "below"
  local fallback_skeleton = function()
    if item.kind == "data" then
      return string.format('data "%s" "name" {\n}\n', item.name)
    end
    return string.format('resource "%s" "name" {\n}\n', item.name)
  end

  if not vim.api.nvim_win_is_valid(win) then
    local skel = fallback_skeleton()
    vim.notify("origin window is gone; yanked instead", vim.log.levels.WARN)
    vim.fn.setreg("+", skel)
    vim.fn.setreg('"', skel)
    return
  end

  local buf = vim.api.nvim_win_get_buf(win)
  local cursor = vim.api.nvim_win_get_cursor(win)
  local insert_row, relocated = find_safe_insert_row(buf, cursor[1], direction)

  -- When relocated out of an enclosing block, pad with two blank lines so
  -- the new block is visually separated from the adjacent one. Where the
  -- snippet lands depends on direction:
  --   below → snippet on the SECOND blank (first becomes the gap above it)
  --   above → snippet on the FIRST blank (second becomes the gap below it)
  -- When inserting at the cursor (no relocation) a single blank suffices.
  local pad_lines = relocated and { "", "" } or { "" }
  local cursor_offset
  if not relocated then
    cursor_offset = 1
  elseif direction == "above" then
    cursor_offset = 1
  else
    cursor_offset = 2
  end

  vim.api.nvim_buf_set_lines(buf, insert_row, insert_row, false, pad_lines)
  vim.api.nvim_set_current_win(win)
  vim.api.nvim_win_set_cursor(win, { insert_row + cursor_offset, 0 })

  local expand = function(snippet)
    local ok_ls, luasnip = pcall(require, "luasnip")
    if ok_ls and type(luasnip.lsp_expand) == "function" then
      luasnip.lsp_expand(snippet)
      return
    end
    -- Last-ditch fallback: paste the literal snippet text without tabstops.
    local lines = vim.split(snippet, "\n", {})
    vim.api.nvim_buf_set_lines(buf, insert_row, insert_row + 1, false, lines)
    vim.api.nvim_win_set_cursor(win, { insert_row + 1, 0 })
  end

  M.get_snippet(client, item.name, item.kind, function(snippet)
    vim.schedule(function()
      -- Re-enter insert mode at the blank line so LuaSnip's expand drops
      -- into insert with the first tabstop selected.
      vim.cmd("startinsert")
      expand(snippet or fallback_skeleton())
    end)
  end)
end

--- Open full docs in a floating markdown scratch buffer.
--- @param title string Window title
--- @param markdown string Rendered markdown body
--- @param return_to integer|nil Window to refocus after closing
local function open_docs_float(title, markdown, return_to)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(markdown, "\n"))
  local width = math.min(120, math.floor(vim.o.columns * 0.8))
  local height = math.min(40, math.floor(vim.o.lines * 0.8))
  local ok, winid = pcall(vim.api.nvim_open_win, buf, true, {
    relative = "editor",
    style = "minimal",
    border = "rounded",
    title = " " .. title .. " ",
    title_pos = "center",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    -- Snacks picker floats sit around zindex 40-50; go higher so the
    -- docs float is visible on top of them.
    zindex = 200,
    focusable = true,
  })
  if not ok then
    vim.notify("[tfs] nvim_open_win failed: " .. tostring(winid), vim.log.levels.ERROR)
    return
  end
  vim.wo[winid].wrap = true
  vim.wo[winid].linebreak = true
  vim.wo[winid].breakindent = true
  -- We arrive from the picker's prompt buffer (insert mode); force normal
  -- mode in the docs float so `q` / `<Esc>` close it immediately.
  vim.cmd("stopinsert")

  local function close()
    if vim.api.nvim_win_is_valid(winid) then
      vim.api.nvim_win_close(winid, true)
    end
    if return_to and vim.api.nvim_win_is_valid(return_to) then
      pcall(vim.api.nvim_set_current_win, return_to)
    end
  end
  for _, lhs in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", lhs, close, { buffer = buf, nowait = true, silent = true })
  end
end

--- Open the snacks picker with search results.
--- @param client any terraformls LSP client handle
--- @param query string
--- @param origin_win integer
function M.open_picker(client, query, origin_win)
  M.search(client, query, function(items)
    if #items == 0 then
      vim.notify("no matches for " .. vim.inspect(query), vim.log.levels.INFO)
      return
    end

    local snacks_ok, snacks = pcall(require, "snacks")
    if not snacks_ok then
      vim.notify("snacks.nvim is required for TerraformSearch", vim.log.levels.ERROR)
      return
    end

    -- Cache resolved docs per {name, kind} for the session (picker lifetime).
    local doc_cache = {}

    -- Shared action closures (captured by both the picker keymaps and the
    -- `actions` table). Defined as locals to sidestep any action-by-name
    -- lookup that might be interfered with by completion plugins on the
    -- picker's prompt buffer.
    local open_docs_action = function(item)
      if not item or not item.name or not item.kind then return end
      local picker_win = vim.api.nvim_get_current_win()
      local cache_key = item.name .. ":" .. item.kind
      local cached = doc_cache[cache_key]
      if cached then
        open_docs_float(item.name, cached, picker_win)
      else
        M.get_doc(client, item.name, item.kind, function(markdown, _url)
          vim.schedule(function()
            open_docs_float(item.name, markdown, picker_win)
          end)
        end)
      end
    end

    local yank_name_action = function(item)
      if not item then return end
      vim.fn.setreg("+", item.name)
      vim.fn.setreg('"', item.name)
      vim.notify("yanked " .. item.name, vim.log.levels.INFO)
    end

    local picker_items = {}
    for idx, it in ipairs(items) do
      table.insert(picker_items, {
        idx = idx,
        -- `text` is what snacks' matcher scores against. Include both
        -- name and summary so user can further narrow by either.
        text = (it.name or "") .. " — " .. (it.summary or ""),
        name = it.name,
        kind = it.kind,
        provider = it.provider,
        summary = it.summary or "",
        score = it.score,
        registry_url = it.registry_url,
      })
    end

    snacks.picker({
      title = string.format("Terraform Search: %s", query),
      items = picker_items,
      -- Server already ranked; disable the matcher's sorting so our score order shows.
      matcher = { sort_empty = false, frecency = false },
      -- Keep the picker alive when focus moves to the <C-d> docs float,
      -- so returning to it preserves query + selection state.
      auto_close = false,
      -- Docs are long markdown; override the default 30% preview with ~60%
      -- so resource names and prose aren't both fighting for space.
      layout = {
        layout = {
          box = "vertical",
          backdrop = false,
          row = -1,
          width = 0,
          height = 0,
          border = "top",
          title = " {title} {live} {flags}",
          title_pos = "left",
          { win = "input", height = 1, border = "bottom" },
          {
            box = "horizontal",
            { win = "list", border = "none", height = 0, width = 0.4 },
            { win = "preview", title = "{preview}", width = 0, height = 0, border = "left" },
          },
        },
      },
      format = function(item)
        local kind_tag = item.kind == "data" and "D" or "R"
        local kind_hl = item.kind == "data" and "SnacksPickerSpecial" or "SnacksPickerKeyword"
        return {
          { kind_tag .. " ", kind_hl },
          { item.name, "SnacksPickerFile" },
          { "  " .. item.summary, "SnacksPickerComment" },
        }
      end,
      preview = function(ctx)
        local item = ctx.item
        if not item then return end
        local cache_key = item.name .. ":" .. item.kind
        local cached = doc_cache[cache_key]
        if cached then
          ctx.preview:set_lines(vim.split(cached, "\n"))
          ctx.preview:highlight({ ft = "markdown" })
          return
        end
        ctx.preview:set_lines({ "Loading docs for " .. item.name .. "..." })
        M.get_doc(client, item.name, item.kind, function(markdown, _url)
          doc_cache[cache_key] = markdown
          -- ctx may refer to a now-stale preview state if the user moved;
          -- snacks handles that internally. Schedule to be safe.
          vim.schedule(function()
            if ctx.item and ctx.item.name == item.name then
              ctx.preview:set_lines(vim.split(markdown, "\n"))
              ctx.preview:highlight({ ft = "markdown" })
            end
          end)
        end)
      end,
      confirm = function(picker, item)
        picker:close()
        if item then
          smart_insert(origin_win, client, item, "below")
        end
      end,
      actions = {
        tfs_open_docs = function(_picker, item) open_docs_action(item) end,
        tfs_yank_name = function(_picker, item) yank_name_action(item) end,
        tfs_insert_above = function(picker, item)
          picker:close()
          if item then
            smart_insert(origin_win, client, item, "above")
          end
        end,
      },
      win = {
        input = {
          keys = {
            ["<c-x>"] = { "tfs_insert_above", mode = { "n", "i" }, desc = "insert above enclosing block" },
            ["<s-cr>"] = { "tfs_insert_above", mode = { "n", "i" }, desc = "insert above (terminal-dependent)" },
            ["<c-g>"] = { "tfs_open_docs", mode = { "n", "i" }, desc = "open docs (float)" },
            ["<c-y>"] = { "tfs_yank_name", mode = { "n", "i" }, desc = "yank resource name" },
          },
        },
        list = {
          keys = {
            ["<c-x>"] = { "tfs_insert_above", mode = { "n" }, desc = "insert above enclosing block" },
            ["<s-cr>"] = { "tfs_insert_above", mode = { "n" }, desc = "insert above (terminal-dependent)" },
            ["<c-g>"] = { "tfs_open_docs", mode = { "n" }, desc = "open docs (float)" },
            ["<c-y>"] = { "tfs_yank_name", mode = { "n" }, desc = "yank resource name" },
          },
        },
        preview = {
          wo = {
            wrap = true,
            linebreak = true,
            breakindent = true,
          },
        },
      },
    })
  end)
end

--- Entry point. Prompt for query if none provided, then open the picker.
--- @param query string|nil
function M.run(query)
  local client, reason = M.find_client()
  if not client then
    vim.notify(reason or "no client", vim.log.levels.ERROR)
    return
  end
  local origin_win = vim.api.nvim_get_current_win()
  local go = function(q)
    if not q or q == "" then return end
    M.open_picker(client, q, origin_win)
  end
  if query and query ~= "" then
    go(query)
  else
    vim.ui.input({ prompt = "Search Terraform docs: " }, function(input)
      if input == nil then return end
      go(input)
    end)
  end
end

--- Register the :TerraformSearch user command.
function M.setup()
  vim.api.nvim_create_user_command("TerraformSearch", function(opts)
    M.run(opts.args ~= "" and opts.args or nil)
  end, { nargs = "?" })
end

return M
