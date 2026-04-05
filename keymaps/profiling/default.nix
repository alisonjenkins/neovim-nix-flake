[
  {
    mode = "n";
    key = "<leader>plf";
    action = "<cmd>PerfLoadFlat<CR>";
    options = {
      desc = "Load perf flat";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>plc";
    action = "<cmd>PerfLoadCallGraph<CR>";
    options = {
      desc = "Load perf call graph";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>plg";
    action = "<cmd>PerfLoadFlameGraph<CR>";
    options = {
      desc = "Load flamegraph";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>pa";
    action = "<cmd>PerfAnnotate<CR>";
    options = {
      desc = "Annotate";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>pt";
    action = "<cmd>PerfToggleAnnotations<CR>";
    options = {
      desc = "Toggle annotations";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>pf";
    action = "<cmd>PerfAnnotateFunction<CR>";
    options = {
      desc = "Annotate function";
      silent = true;
    };
  }
  {
    mode = "v";
    key = "<leader>pa";
    action = "<cmd>PerfAnnotateSelection<CR>";
    options = {
      desc = "Annotate selection";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>ph";
    action = "<cmd>PerfHottestSymbols<CR>";
    options = {
      desc = "Hottest symbols";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>pL";
    action = "<cmd>PerfHottestLines<CR>";
    options = {
      desc = "Hottest lines";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>pe";
    action = "<cmd>PerfPickEvent<CR>";
    options = {
      desc = "Pick event";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>pc";
    action = "<cmd>PerfCycleFormat<CR>";
    options = {
      desc = "Cycle format";
      silent = true;
    };
  }
]
