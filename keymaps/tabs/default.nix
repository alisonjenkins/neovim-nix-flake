[
  {
    mode = "n";
    key = "<leader>Tn";
    action = "<cmd>tabedit<CR>";
    options = {
      desc = "New tab";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>Te";
    action = ":tabedit ";
    options = {
      desc = "Edit in new tab";
      silent = true;
    };
  }
]
