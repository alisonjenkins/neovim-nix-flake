[
  {
    mode = "n";
    key = "<leader>bd";
    action = "<cmd>lua require('bufdelete').bufdelete(0, true)<cr>";
    options = {
      desc = "Close Buffer";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>bs";
    action = "<cmd>Telescope buffers<cr>";
    options = {
      desc = "Switch Buffer";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "[b";
    action = "<cmd>bprevious<cr>";
    options = {
      desc = "Open previous buffer";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "]b";
    action = "<cmd>bnext<cr>";
    options = {
      desc = "Move to next buffer";
      silent = true;
    };
  }
]
