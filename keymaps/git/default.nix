[
  {
    mode = "n";
    key = "<leader>ga";
    action = "<cmd>Gwrite<CR>";
    options = {
      desc = "";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>gb";
    action = "<cmd>Telescope branches<CR>";
    options = {
      desc = "";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>gl";
    action = "<cmd>Git log<CR>";
    options = {
      desc = "";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>gs";
    action = "<cmd>Git<CR>";
    options = {
      desc = "";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>gp";
    action = "<cmd>Git push<CR>";
    options = {
      desc = "";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>gll";
    action = ''lua require"gitlinker".get_repo_url()<cr>'';
    options = {
      desc = "";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>glb";
    action = ''
      lua require"gitlinker".get_repo_url({action_callback = require"gitlinker.actions".open_in_browser})<cr>'';
    options = {
      desc = "";
      silent = true;
    };
  }
]
