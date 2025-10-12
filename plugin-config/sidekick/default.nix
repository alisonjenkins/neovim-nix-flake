{
  sidekick = {
    enable = true;

    settings = {
      keys = {};

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
