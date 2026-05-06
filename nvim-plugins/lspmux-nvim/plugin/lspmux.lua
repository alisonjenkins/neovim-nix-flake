-- plugin/lspmux.lua — autoloaded by Neovim on startup so the user
-- commands are available without an explicit require/setup call.
-- The init module's `setup()` is still useful for binary-path
-- overrides; this file only owns command registration.

if vim.g.loaded_lspmux then
  return
end
vim.g.loaded_lspmux = true

vim.api.nvim_create_user_command("LspmuxInfo", function()
  require("lspmux").info()
end, { desc = "Show lspmux daemon version, uptime, and connected LSPs" })

vim.api.nvim_create_user_command("LspmuxRestart", function()
  require("lspmux").restart()
end, { desc = "Restart the lspmux daemon and reattach all language servers" })
