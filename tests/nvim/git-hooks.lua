-- Failing commit hooks must show their full output, and the typed commit message
-- must survive until a commit succeeds. Runs in a throwaway repo.
local h = dofile(os.getenv("TEST_DIR") .. "/harness.lua")
local tmp = os.getenv("TMPDIR") or "/tmp"

local function hook_dir(name, hook, body)
  local dir = tmp .. "/hooks-" .. name
  vim.fn.mkdir(dir, "p")
  -- Absolute bash: the Nix sandbox has no /usr/bin/env
  vim.fn.writefile({ "#!" .. os.getenv("BASH_BIN"), unpack(vim.split(body, "\n")) }, dir .. "/" .. hook)
  vim.fn.setfperm(dir .. "/" .. hook, "rwxr-xr-x")
  return dir
end

local msg_fail = hook_dir("msgfail", "commit-msg", [[
for i in $(seq 1 25); do printf '\033[31mcommitlint: problem %d\033[0m\n' "$i"; done
echo "subject may not be empty [subject-empty]" >&2
exit 1]])
local pre_fail = hook_dir("prefail", "pre-commit", [[
printf 'trim trailing whitespace....\033[41mFailed\033[0m\n'
echo "- hook id: trailing-whitespace" >&2
exit 1]])
local no_hooks = tmp .. "/hooks-none"
vim.fn.mkdir(no_hooks, "p")

local git_dir = vim.fn.FugitiveGitDir()
local backup = git_dir .. "/COMMIT_EDITMSG.nvim-backup"
local function head() return vim.trim(vim.fn.system("git rev-parse HEAD")) end
local head_before = head()

local function commit(hooks)
  h.reset_windows()
  vim.cmd("Git -c core.hooksPath=" .. hooks .. " commit --allow-empty")
end

local function wait_for_failure(what)
  return { what = what, ["until"] = function() return #h.notes_matching("Git commit failed") > 0 end }
end

local function top_lines(n) return vim.api.nvim_buf_get_lines(0, 0, n, false) end

local steps = {
  function()
    commit(msg_fail)
    h.check(vim.fn.expand("%:t") == "COMMIT_EDITMSG", "commit opens the message editor", vim.fn.expand("%:t"))
    vim.api.nvim_buf_set_lines(0, 0, 1, false, { "feat: keep this message", "", "Body line." })
    vim.cmd("wq")
  end,
  wait_for_failure("commit-msg failure"),
  function()
    local lines = h.git_split_lines()
    h.check(#lines == 26, "commit-msg failure shows all hook output", #lines .. " lines")
    h.check(lines[1] == "commitlint: problem 1", "ANSI colour codes are stripped", vim.inspect(lines[1]))
    h.check(vim.fn.filereadable(backup) == 1, "failed commit leaves a saved message")
    h.check(#h.notes_matching("message saved") > 0, "failure notice says the message was saved")
  end,

  function()
    commit(msg_fail)
    h.check(vim.deep_equal(top_lines(3), { "feat: keep this message", "", "Body line." }),
      "next commit restores the saved message", vim.inspect(top_lines(3)))
    -- Emptying the message is a deliberate abort
    vim.api.nvim_buf_set_lines(0, 0, 3, false, {})
    vim.cmd("wq")
  end,
  wait_for_failure("aborted commit to exit"),
  function()
    h.check(vim.fn.filereadable(backup) == 0, "an emptied message discards the saved one")
  end,

  function() commit(pre_fail) end,
  wait_for_failure("pre-commit failure"),
  function()
    local lines = h.git_split_lines()
    h.check(vim.tbl_contains(lines, "- hook id: trailing-whitespace"), "pre-commit failure shows hook output", vim.inspect(lines))
    h.check(#h.notes_matching("message saved") == 0, "no saved message is claimed when none exists")
  end,

  function()
    commit(msg_fail)
    vim.api.nvim_buf_set_lines(0, 0, 1, false, { "feat: lands second time" })
    vim.cmd("wq")
  end,
  wait_for_failure("commit-msg failure before retry"),
  function()
    commit(no_hooks)
    h.check(top_lines(1)[1] == "feat: lands second time", "retry is prefilled with the saved message", vim.inspect(top_lines(1)))
    vim.cmd("wq")
  end,
  { what = "retried commit to land", ["until"] = function() return head() ~= head_before end },
  function()
    h.check(vim.trim(vim.fn.system("git log -1 --format=%s")) == "feat: lands second time", "retried commit uses the saved message")
    h.check(vim.fn.filereadable(backup) == 0, "a successful commit discards the saved message")
  end,

  function()
    vim.fn.writefile({ vim.json.encode({ head = "0000000000000000000000000000000000000000", lines = { "stale message" } }) }, backup)
    commit(msg_fail)
    h.check(top_lines(1)[1] ~= "stale message", "a message saved before HEAD moved is not restored", vim.inspect(top_lines(1)))
    h.check(vim.fn.filereadable(backup) == 0, "a message saved before HEAD moved is discarded")
    vim.api.nvim_buf_set_lines(0, 0, -1, false, {})
    vim.cmd("wq")
  end,
  wait_for_failure("final aborted commit to exit"),
}

h.run(steps, 120000)
