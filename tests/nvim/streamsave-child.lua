-- Run by streamsave.lua in a separate Neovim that the test kills with SIGKILL. Saves SV_PATH after
-- the edits in SV_EDITS (a JSON list of { offset, text }), and when the save reaches the hook named
-- by SV_STOP it writes SV_MARKER and waits to be killed. Without SV_STOP it writes SV_MARKER just
-- before the save starts.
local sv = require("streamview")
local save = require("streamview_save")
sv.opts.editable = true

local path = os.getenv("SV_PATH")
local marker = os.getenv("SV_MARKER")
local stop = os.getenv("SV_STOP")
local after = tonumber(os.getenv("SV_AFTER") or "0")

local function touch(text)
  local f = assert(io.open(marker, "w"))
  f:write(text)
  f:close()
end

if os.getenv("SV_SLOW") == "1" then
  -- every slice ends at once, so the save takes many turns of the event loop
  local clock = 0
  vim.uv.hrtime = function()
    clock = clock + 20e6
    return clock
  end
end

vim.cmd("StreamView! " .. vim.fn.fnameescape(path))
local S = sv.state()
for _, edit in ipairs(vim.json.decode(os.getenv("SV_EDITS"))) do
  S.r:apply({ { start = edit[1], stop = edit[1] + #edit[2], text = edit[2] } })
end

if stop and stop ~= "" then
  save.hooks[stop] = function(pos)
    if (pos or 0) < after then return end
    touch(stop)
    vim.wait(600000, function() return false end)
  end
else
  touch("start")
end
sv.write(S, { strategy = "inplace" }, function(ok, err) touch("done " .. tostring(ok) .. " " .. tostring(err)) end)
vim.wait(600000, function() return false end)
