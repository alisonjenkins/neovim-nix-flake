[
  {
    mode = "n";
    key = "<leader>acc";
    action = "<cmd>ClaudeCode<CR>";
    options = {
      desc = "Toggle Claude Code terminal";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>acf";
    action = "<cmd>ClaudeCodeFocus<CR>";
    options = {
      desc = "Focus Claude Code terminal";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>acr";
    action = "<cmd>ClaudeCode --resume<CR>";
    options = {
      desc = "Resume Claude Code session";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>acC";
    action = "<cmd>ClaudeCode --continue<CR>";
    options = {
      desc = "Continue Claude Code session";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>acm";
    action = "<cmd>ClaudeCodeSelectModel<CR>";
    options = {
      desc = "Select Claude Code model";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>acb";
    action = "<cmd>ClaudeCodeAdd %<CR>";
    options = {
      desc = "Add current buffer to Claude context";
      silent = true;
    };
  }
  {
    mode = "v";
    key = "<leader>acs";
    action = "<cmd>ClaudeCodeSend<CR>";
    options = {
      desc = "Send selection to Claude Code";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>aca";
    action = "<cmd>ClaudeCodeDiffAccept<CR>";
    options = {
      desc = "Accept Claude Code diff";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>acd";
    action = "<cmd>ClaudeCodeDiffDeny<CR>";
    options = {
      desc = "Deny Claude Code diff";
      silent = true;
    };
  }
]
