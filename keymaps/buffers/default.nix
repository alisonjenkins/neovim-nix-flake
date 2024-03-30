[
  {
    mode = "n";
    key = "<leader>bd";
    action = "<cmd>BufferClose<cr>";
    options = {
      desc = "Close Buffer";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>bd";
    action = "<cmd>BufferDelete<cr>";
    options = {
      desc = "Buffer Delete";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>bp";
    action = "<cmd>BufferPick<cr>";
    options = {
      desc = "Pick Buffer";
      silent = true;
    };
  }
]
