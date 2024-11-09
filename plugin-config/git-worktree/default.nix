{ pkgs, ... }: {
  extraConfigLua = ''
    local Hooks = require("git-worktree.hooks")
    local config = require('git-worktree.config')
    local update_on_switch = Hooks.builtins.update_current_buffer_on_switch

    Hooks.register(Hooks.type.SWITCH, function (path, prev_path)
    vim.notify("Moved from " .. prev_path .. " to " .. path)
    update_on_switch(path, prev_path)
    end)

    Hooks.register(Hooks.type.DELETE, function ()
    vim.cmd(config.update_on_change_command)
    end)
    require('telescope').load_extension('git_worktree')
  '';

  extraPlugins = with pkgs.vimPlugins; [
    git-worktree-nvim
  ];
}
