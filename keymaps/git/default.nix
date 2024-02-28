[
  {
    mode = "n";
    key = "<leader>ga";
    action = "<cmd>Gwrite<CR>";
    options = {
      desc = "Git Add";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>gb";
    action = "<cmd>Telescope git_branches<CR>";
    options = {
      desc = "Branches";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>gl";
    action = "<cmd>Git log<CR>";
    options = {
      desc = "Git Log";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>gs";
    action = "<cmd>Git<CR>";
    options = {
      desc = "Git Status";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>gp";
    action = "<cmd>Git push<CR>";
    options = {
      desc = "Git Push";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>gLL";
    action = ''lua require"gitlinker".get_repo_url()<cr>'';
    options = {
      desc = "Git Linker Copy Repo URL";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>gLb";
    action = ''
      lua require"gitlinker".get_repo_url({action_callback = require"gitlinker.actions".open_in_browser})<cr>'';
    options = {
      desc = "Git Linker Open In Browser";
      silent = true;
    };
  }
]
