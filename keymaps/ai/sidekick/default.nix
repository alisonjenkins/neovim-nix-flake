[
  {
    mode = "i";
    key = "<C-l>";
    action = "<cmd>lua require('sidekick').nes_jump_or_apply()<cr>";
    options = {
      desc = "Goto / Apply Next Edit Suggestion";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<C-y>";
    action = "<cmd>lua require('sidekick').nes_jump_or_apply()<cr>";
    options = {
      desc = "Goto / Apply Next Edit Suggestion";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>asa";
    action = "<cmd>lua require('sidekick.cli').toggle()<cr>";
    options = {
      desc = "Sidekick Toggle CLI";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>asA";
    action = "<cmd>lua require('sidekick.cli').toggle({ name = 'aider', focus = true })<cr>";
    options = {
      desc = "Sidekick Toggle Aider";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>asc";
    action = "<cmd>lua require('sidekick.cli').toggle({ name = 'copilot', focus = true })<cr>";
    options = {
      desc = "Sidekick Toggle Copilot";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>asC";
    action = "<cmd>lua require('sidekick.cli').toggle({ name = 'claude', focus = true })<cr>";
    options = {
      desc = "Sidekick Toggle Claude";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>asg";
    action = "<cmd>lua require('sidekick.cli').toggle({ name = 'Gemini', focus = true })<cr>";
    options = {
      desc = "Sidekick Toggle Gemini";
      silent = true;
    };
  }
  {
    mode = "v";
    key = "<leader>ass";
    action = "<cmd>lua require('sidekick.cli').select({ filter = { installed = true } })<cr>";
    options = {
      desc = "Select CLI";
      silent = true;
    };
  }
  {
    mode = ["n" "x"];
    key = "<leader>ast";
    action = "<cmd>lua require('sidekick.cli').send({ msg = '{this}' })<cr>";
    options = {
      desc = "Send This";
      silent = true;
    };
  }
  {
    mode = "x";
    key = "<leader>asv";
    action = "<cmd>lua require('sidekick.cli').send({ msg = '{selection}' })<cr>";
    options = {
      desc = "Send Visual Selection";
      silent = true;
    };
  }
  {
    mode = ["n" "x"];
    key = "<leader>asp";
    action = "<cmd>lua require('sidekick.cli').prompt()<cr>";
    options = {
      desc = "Sidekick Select Prompt";
      silent = true;
    };
  }
  {
    mode = ["n" "x"];
    key = "<leader>asf";
    action = "<cmd>lua require('sidekick.cli').focus()<cr>";
    options = {
      desc = "Sidekick Switch Focus";
      silent = true;
    };
  }
]
