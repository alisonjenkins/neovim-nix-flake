let
  config = import ./config.nix;
in
{
  sidekick = {
    enable = true;

    settings = {
      nes = {
        enabled = config.nesEnabled;
      };

      keys = { };

      cli = {
        mux = {
          # the tmux backend has nothing to attach to outside tmux
          enabled.__raw = "(vim.env.TMUX or '') ~= ''";
          backend = "tmux";

          create = "split";
          split = {
            vertical = true;
            size = 0.4;
          };
        };
      };

      prompts = {
        explain = "Explain this code";
        optimize = "How can this code be optimized?";

        diagnostics = {
          diagnostics = true;
          msg = "What do the diagnostics in this file mean?";
        };

        diagnostics_all = {
          msg = "Can you help me fix these issues?";

          diagnostics = {
            all = true;
          };
        };

        fix = {
          msg = "Can you fix the issues in this code?";
          diagnostics = true;
        };

        review = {
          msg = "Can you review this code for any issues or improvements?";
          diagnostics = true;
        };
      };
    };
  };
}
