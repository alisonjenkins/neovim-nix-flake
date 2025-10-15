[
  {
    mode = "n";
    key = "<leader>jd";
    action = "<cmd>J describe<CR>";
    options = {
      desc = "JJ describe";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>jD";
    action = "<cmd>J diff<CR>";
    options = {
      desc = "JJ diff";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>je";
    action = "<cmd>J edit<CR>";
    options = {
      desc = "JJ edit";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>ji";
    action = "<cmd>J git init --colocate<CR>";
    options = {
      desc = "JJ git init --colocate";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>jl";
    action = "<cmd>J log<CR>";
    options = {
      desc = "JJ log";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>jL";
    action = "<cmd>J log -r 'all()'<CR>";
    options = {
      desc = "JJ log all";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>jn";
    action = "<cmd>J new<CR>";
    options = {
      desc = "JJ new";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>js";
    action = "<cmd>J status<CR>";
    options = {
      desc = "JJ status";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>jS";
    action = "<cmd>J squash<CR>";
    options = {
      desc = "JJ squash";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>jt";
    action = "<cmd>lua local cmd = require('jj.cmd'); cmd.j 'tug'; cmd.log {}<CR>";
    options = {
      desc = "JJ tug and log";
      silent = true;
    };
  }
]
