{
  trouble = {
    enable = true;

    lazyLoad.settings = {
      cmd = [ "Trouble" ];
      keys = [ "<leader>x" ];
    };

    settings = {
      auto_refresh = true;
      # Keep the source buffer focused when Trouble opens so its
      # `Main.get()` fallback tracks a real source window. With
      # `focus = true` on Neovim 0.12, Trouble's window could end
      # up treated as the "main" window, and subsequent jumps
      # crashed with `Invalid 'window': Expected Lua number` from
      # `view/init.lua` — the Trouble window gets closed mid-jump
      # and the stashed window ID becomes invalid.
      focus = false;
    };
  };
}
