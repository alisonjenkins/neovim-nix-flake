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
  # {
  #   mode = "n";
  #   key = "<leader>se";
  #   action = "<cmd>Telescope file_browser<CR>";
  #   options = {
  #     desc = "Explore files (File Browser)";
  #     silent = true;
  #   };
  # }
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
    action = "<cmd>lua require('snacks').picker.files()<CR>";
    options = {
      desc = "Files";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>sr";
    action = "<cmd>lua require('snacks').picker.recent()<CR>";
    options = {
      desc = "Find recently edited files";
      silent = true;
    };
  }
  # {
  #   mode = "n";
  #   key = "<leader>sh";
  #   action = "<cmd>Telescope help_tags<CR>";
  #   options = {
  #     desc = "Help tags";
  #     silent = true;
  #   };
  # }
  {
    mode = "n";
    key = "<leader>st";
    action = "<cmd>lua require('snacks').picker.grep()<CR>";
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
  {
    mode = "n";
    key = "<leader>sl";
    action = "<cmd>lua require('snacks').picker.lines()<CR>";
    options = {
      desc = "Lines in current file";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>sz";
    action = "<cmd>lua require('snacks').picker.zoxide()<CR>";
    options = {
      desc = "Search for projects via zoxide";
      silent = true;
    };
  }
]
