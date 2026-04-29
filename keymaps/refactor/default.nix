[
  {
    mode = [ "n" "x" ];
    key = "<leader>rr";
    action = "<cmd>Refactor<CR>";
    options = {
      desc = "Refactor menu";
      silent = true;
    };
  }
  {
    mode = "x";
    key = "<leader>re";
    action = "<cmd>Refactor extract<CR>";
    options = {
      desc = "Extract function";
      silent = true;
    };
  }
  {
    mode = "x";
    key = "<leader>rf";
    action = "<cmd>Refactor extract_to_file<CR>";
    options = {
      desc = "Extract function to file";
      silent = true;
    };
  }
  {
    mode = "x";
    key = "<leader>rv";
    action = "<cmd>Refactor extract_var<CR>";
    options = {
      desc = "Extract variable";
      silent = true;
    };
  }
  {
    mode = "x";
    key = "<leader>rb";
    action = "<cmd>Refactor extract_block<CR>";
    options = {
      desc = "Extract block";
      silent = true;
    };
  }
  {
    mode = "x";
    key = "<leader>rB";
    action = "<cmd>Refactor extract_block_to_file<CR>";
    options = {
      desc = "Extract block to file";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>ri";
    action = "<cmd>Refactor inline_var<CR>";
    options = {
      desc = "Inline variable";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>rI";
    action = "<cmd>Refactor inline_func<CR>";
    options = {
      desc = "Inline function";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>rp";
    action = "<cmd>Refactor debug.printf<CR>";
    options = {
      desc = "Insert printf";
      silent = true;
    };
  }
  {
    mode = [ "n" "x" ];
    key = "<leader>rP";
    action = "<cmd>Refactor debug.print_var<CR>";
    options = {
      desc = "Insert print_var";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>rc";
    action = "<cmd>Refactor debug.cleanup<CR>";
    options = {
      desc = "Cleanup debug prints";
      silent = true;
    };
  }
]
