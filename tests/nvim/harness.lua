-- Minimal harness for headless Neovim tests: named checks, notification capture,
-- and steps that run on the event loop so jobs and fugitive's resume can progress.
local M = { failures = {}, notes = {} }

function M.check(ok, name, detail)
  if ok then
    io.stdout:write("PASS  " .. name .. "\n")
  else
    io.stdout:write("FAIL  " .. name .. (detail and ("\n      " .. detail) or "") .. "\n")
    table.insert(M.failures, name)
  end
end

function M.finish()
  io.stdout:write(string.format("\n%d failed\n", #M.failures))
  vim.cmd(#M.failures == 0 and "qa!" or "cquit 1")
end

-- Notification plugins replace vim.notify lazily, so re-wrap whenever it changes.
local wrapper
function M.capture_notify()
  if vim.notify == wrapper then return end
  local inner = vim.notify
  wrapper = function(msg, level)
    table.insert(M.notes, msg)
    return inner(msg, level)
  end
  vim.notify = wrapper
end

function M.notes_matching(text)
  local found = {}
  for _, n in ipairs(M.notes) do
    if n:find(text, 1, true) then table.insert(found, n) end
  end
  return found
end

function M.git_split_lines()
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    local b = vim.api.nvim_win_get_buf(w)
    if vim.bo[b].filetype == "git" then return vim.api.nvim_buf_get_lines(b, 0, -1, false) end
  end
  return {}
end

function M.reset_windows()
  vim.cmd("silent! only!")
  M.notes = {}
  M.capture_notify()
end

-- Each step is a function, or { until = fn, what = "..." } polled until true.
function M.run(steps, total_timeout_ms)
  vim.defer_fn(function()
    M.check(false, "suite finished within " .. total_timeout_ms .. " ms")
    M.finish()
  end, total_timeout_ms)

  local step_timeout_ms = 15000
  local function run(i, started)
    if i > #steps then return M.finish() end
    local step = steps[i]
    if type(step) == "table" then
      M.capture_notify()
      if step["until"]() then return run(i + 1) end
      started = started or vim.uv.now()
      if vim.uv.now() - started > step_timeout_ms then
        M.check(false, "waited for " .. step.what)
        return M.finish()
      end
      return vim.defer_fn(function() run(i, started) end, 50)
    end
    local ok, err = pcall(step)
    if not ok then
      M.check(false, "step " .. i .. " ran without error", tostring(err))
      return M.finish()
    end
    vim.defer_fn(function() run(i + 1) end, 50)
  end

  vim.defer_fn(function() run(1) end, 100)
end

return M
