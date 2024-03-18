[
  {
    mode = "v";
    key = "<leader>gLL";
    action = ''<cmd>lua require"gitlinker".get_repo_url()<CR>'';
    options = {
      desc = "Git Add";
      silent = true;
    };
  }
  {
    mode = "v";
    key = "<leader>gLb";
    action = ''<cmd>lua require"gitlinker".get_repo_url({action_callback = require"gitlinker.actions".open_in_browser})<CR>'';
    options = {
      desc = "Git Add";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>gLL";
    action = ''<cmd>lua require"gitlinker".get_repo_url()<cr>'';
    options = {
      desc = "Git Linker Copy Repo URL";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>gLb";
    action = ''<cmd>lua require"gitlinker".get_repo_url({action_callback = require"gitlinker.actions".open_in_browser})<cr>'';
    options = {
      desc = "Git Linker Open In Browser";
      silent = true;
    };
  }
]
