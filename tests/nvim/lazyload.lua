-- Plugins that load on first use (neotest, pipeline.nvim), the second deferred stage, and the trimmed
-- 'packpath'. Runs in a throwaway repo; no network.
local h = dofile(os.getenv("TEST_DIR") .. "/harness.lua")

local start_dir = vim.uv.cwd()

local steps = {
  function()
    for _, dir in ipairs(vim.opt.packpath:get()) do
      local holds_packages = false
      for _, sub in ipairs({ "pack", "start", "opt" }) do
        if vim.uv.fs_stat(dir .. "/" .. sub) then holds_packages = true end
      end
      h.check(holds_packages, "packpath entry holds packages: " .. dir)
    end

    h.check(package.loaded["fidget"] ~= nil, "fidget loaded by the second deferred stage")
    h.check(package.loaded["smear_cursor"] ~= nil, "smear-cursor loaded by the second deferred stage")

    h.check(vim.fn.exists(":Neotest") == 2, ":Neotest exists")
    h.check(package.loaded["neotest"] ~= nil, "neotest loaded by the third deferred stage")
    h.check(vim.fn.exists(":Pipeline") == 2, ":Pipeline exists before pipeline.nvim is loaded")
    h.check(vim.fn.exists(":GhActions") == 2, ":GhActions exists before pipeline.nvim is loaded")
    h.check(package.loaded["pipeline"] == nil, "pipeline.nvim is not loaded at startup")
  end,

  function()
    local completion = vim.fn.getcompletion("Pipeline ", "cmdline")
    h.check(
      vim.deep_equal(completion, { "open", "close", "toggle", "remote" }),
      ":Pipeline completes its actions before it is loaded",
      vim.inspect(completion)
    )
    -- setup() reads the git remotes of the current directory: it must run in the directory
    -- Neovim started in, not in wherever :cd has moved to.
    vim.cmd("cd " .. vim.fn.fnameescape(os.getenv("TMPDIR") or "/tmp"))
    h.check(vim.uv.cwd() ~= start_dir, "test setup: the directory changed")
    local ok, err = pcall(vim.cmd, "Pipeline remote")
    h.check(ok, ":Pipeline loads pipeline.nvim and runs", tostring(err))
    h.check(package.loaded["pipeline"] ~= nil, "pipeline.nvim is loaded after the first :Pipeline")
    h.check(
      package.loaded["pipeline"] and package.loaded["pipeline"].init_root == start_dir,
      "pipeline.nvim set up in the startup directory after a :cd",
      tostring(package.loaded["pipeline"] and package.loaded["pipeline"].init_root)
    )
    h.check(vim.uv.cwd() ~= start_dir, "the working directory is restored after the lazy setup")
    h.check(vim.fn.exists(":GhActions") == 2, ":GhActions is the real command after the first :Pipeline")
  end,

  function()
    -- neotest is a dependency of its adapters, so its plugin/ files define :Neotest at startup;
    -- the command only works if setup() has already run.
    h.check(require("neotest").summary ~= nil, "neotest.setup() has run")
    local ok, err = pcall(vim.cmd, "Neotest summary")
    h.check(ok, ":Neotest runs", tostring(err))
  end,
}

h.run(steps, 60000)
