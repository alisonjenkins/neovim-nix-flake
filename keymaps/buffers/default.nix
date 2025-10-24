[
  {
    mode = "n";
    key = "<leader>;";
    action = "<cmd>lua require('snacks').dashboard()<CR>";
    options = {
      desc = "Open Dashboard";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "-";
    action = "<cmd>Oil<cr>";
    options = {
      desc = "Open File Browser in current directory";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>bd";
    action = "<cmd>lua require('snacks').bufdelete()<cr>";
    options = {
      desc = "Close Buffer";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>bs";
    action = "<cmd>lua require('snacks').picker.buffers()<CR>";
    options = {
      desc = "Switch Buffer";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "[b";
    action = "<cmd>CybuPrev<cr>";
    options = {
      desc = "Open previous buffer";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "]b";
    action = "<cmd>CybuNext<cr>";
    options = {
      desc = "Move to next buffer";
      silent = true;
    };
  }
]
