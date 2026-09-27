-- Async git commands must return before git finishes, report git's output, and
-- chain fetch -> rebase. Runs in a throwaway repo with tests/nvim/fake-git on PATH.
local h = dofile(os.getenv("TEST_DIR") .. "/harness.lua")
local state = os.getenv("FAKE_GIT_STATE")
local release = state .. "/release"

vim.env.PATH = os.getenv("FAKE_GIT_BIN") .. ":" .. vim.env.PATH
if vim.fn.exepath("git") ~= os.getenv("FAKE_GIT_BIN") .. "/git" then
  h.check(false, "fake git is first on PATH", "git resolves to " .. vim.fn.exepath("git"))
  return h.finish()
end

local function calls()
  return vim.fn.filereadable(state .. "/calls") == 1 and vim.fn.readfile(state .. "/calls") or {}
end

local function hold() vim.fn.delete(release) end
local function let_go() vim.fn.writefile({}, release) end

local steps = {
  function()
    h.reset_windows()
    hold()
    vim.cmd("GitPullSilent")
    h.check(#h.notes_matching("Git pull completed") == 0, "pull returns control while git is still running")
  end,
  { what = "pull to start", ["until"] = function() return #calls() >= 1 end },
  function()
    h.check(calls()[1] == "pull --no-edit prompt=0 editor=true", "pull runs with --no-edit and prompts disabled", calls()[1])
    let_go()
  end,
  { what = "pull to finish", ["until"] = function() return #h.notes_matching("Git pull completed") > 0 end },
  function()
    local note = h.notes_matching("Git pull completed")[1]
    h.check(note:find("Fast-forward", 1, true) ~= nil, "pull notification includes git's output", note)
  end,

  function()
    h.reset_windows()
    hold()
    vim.cmd("GitPushForceSilent")
    h.check(#h.notes_matching("Git push --force completed") == 0, "force-push returns control while git is still running")
    let_go()
  end,
  { what = "force-push to finish", ["until"] = function() return #h.notes_matching("Git push --force completed") > 0 end },
  function()
    local note = h.notes_matching("Git push --force completed")[1]
    h.check(note:find("remote: line 10", 1, true) ~= nil and note:find("remote: line 11", 1, true) == nil,
      "notification is capped at 10 lines of output", note)
    h.check(note:find("5 more lines (:GitLastOutput)", 1, true) ~= nil, "notification says how many lines were cut", note)
    vim.cmd("GitLastOutput")
    local lines = h.git_split_lines()
    h.check(lines[1] == "# Git push --force" and #lines == 16, ":GitLastOutput shows the full output",
      #lines .. " lines, first " .. tostring(lines[1]))
  end,

  function()
    h.reset_windows()
    vim.fn.delete(state .. "/calls")
    let_go()
    vim.cmd("GitRebaseDefaultSilent")
  end,
  { what = "rebase to finish", ["until"] = function() return #h.notes_matching("Git rebase against") > 0 end },
  function()
    local c = calls()
    h.check(c[1] and c[1]:find("^fetch origin main:main") ~= nil and c[2] and c[2]:find("^rebase %-%-autostash main") ~= nil,
      "rebase runs only after the fetch", vim.inspect(c))
  end,

  function()
    h.reset_windows()
    let_go()
    vim.cmd("GitFetchSilent --fail-test")
  end,
  { what = "failing fetch to finish", ["until"] = function() return #h.notes_matching("Git fetch failed") > 0 end },
  function()
    local lines = h.git_split_lines()
    h.check(lines[1] == "fatal: simulated failure", "a failure opens git's output in a split", vim.inspect(lines))
  end,
}

h.run(steps, 90000)
