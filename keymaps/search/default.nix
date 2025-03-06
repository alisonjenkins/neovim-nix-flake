[
  {
    mode = "n";
    key = "<leader>sb";
    action = "<cmd>lua require('snacks').picker.buffers()<CR>";
    options = {
      desc = "Buffers";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>sB";
    action = "<cmd>require('snacks').picker.git_branches()<CR>";
    options = {
      desc = "Git Branches";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>se";
    action = "<cmd>Telescope file_browser<CR>";
    options = {
      desc = "Explore files (File Browser)";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>f";
    action = "<cmd>lua require('snacks').picker.smart()<CR>";
    options = {
      desc = "Find Files";
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
    key = "<leader>sF";
    action = "<cmd>Telescope frecency<CR>";
    options = {
      desc = "Find Frecency Files";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>sh";
    action = "<cmd>Telescope help_tags<CR>";
    options = {
      desc = "Help tags";
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
    action = "<cmd>lua require('snacks').picker.projects()<CR>";
    options = {
      desc = "Projects";
      silent = true;
    };
  }
]
