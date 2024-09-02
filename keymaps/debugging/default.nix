[
  {
    mode = "n";
    key = "<leader>db";
    action = "<cmd>lua require'dap'.toggle_breakpoint()<cr>";
    options = {
      desc = "DAP Toggle Breakpoint";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>dBc";
    action = "<cmd>lua require'dap'.set_breakpoint(vim.fn.input('Breakpoint condition: '))<cr>";
    options = {
      desc = "DAP Set Conditional Breakpoint";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>dBl";
    action = "<cmd>lua require'dap'.set_breakpoint(nil, nil, vim.fn.input('Log point message: '))<cr>";
    options = {
      desc = "DAP Set Log Breakpoint";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>dc";
    action = "<cmd>lua require'dap'.continue()<cr>";
    options = {
      desc = "DAP Continue";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>dsi";
    action = "<cmd>lua require'dap'.step_into()<cr>";
    options = {
      desc = "DAP Step Into";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>dso";
    action = "<cmd>lua require'dap'.step_over()<cr>";
    options = {
      desc = "DAP Step Over";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>dsO";
    action = "<cmd>lua require'dap'.step_out()<cr>";
    options = {
      desc = "DAP Step Out";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>dt";
    action = "<cmd>lua require'dap'.terminate()<cr>";
    options = {
      desc = "DAP Terminate";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>dr";
    action = "<cmd>lua require'dap'.repl.open()<cr>";
    options = {
      desc = "Open REPL";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>dl";
    action = "<cmd>lua require'dap'.run_last()<cr>";
    options = {
      desc = "Run Last";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>du";
    action = "<cmd>lua require'dapui'.toggle()<cr>";
    options = {
      desc = "Dap UI Toggle";
      silent = true;
    };
  }
]
