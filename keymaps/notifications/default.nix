[
  {
    mode = "n";
    key = "<leader>n";
    action = "<cmd>lua require('snacks').notifier.show_history()<cr>";
    options = {
      desc = "Show notifications";
      silent = true;
    };
  }
]
