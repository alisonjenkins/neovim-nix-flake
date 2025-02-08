[
  {
    mode = "n";
    key = "<leader>::";
    action = "<cmd>terminal<CR>";
    options = {
      desc = "Open terminal";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>:v";
    action = "<cmd>vertical terminal<CR>";
    options = {
      desc = "Open a vertical terminal split";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>:h";
    action = "<cmd>horizontal terminal<CR>";
    options = {
      desc = "Open a horizontal terminal split";
      silent = true;
    };
  }
]
