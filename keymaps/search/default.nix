[
  {
    mode = "n";
    key = "<leader>sb";
    action = "<cmd>Telescope buffers<CR>";
    options = {
      desc = "Buffers";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>sB";
    action = "<cmd>Telescope git_branches<CR>";
    options = {
      desc = "Git Branches";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>sf";
    action = "<cmd>Telescope find_files<CR>";
    options = {
      desc = "Files";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>st";
    action = "<cmd>Telescope live_grep<CR>";
    options = {
      desc = "Live Grep";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>sp";
    action = "<cmd>Telescope projects<CR>";
    options = {
      desc = "Projects";
      silent = true;
    };
  }
]
