[
  {
    mode = "n";
    key = "<leader>ga";
    action = "<cmd>Gwrite<CR>";
    options = {
      desc = "Git Add";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>gb";
    action = "<cmd>Telescope git_branches<CR>";
    options = {
      desc = "Branches";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>gi";
    action = "<cmd>Gitignore<CR>";
    options = {
      desc = "Gitignore";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>gl";
    action = "<cmd>Git log<CR>";
    options = {
      desc = "Git Log";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>gs";
    action = "<cmd>Git<CR>";
    options = {
      desc = "Git Status";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>gpp";
    action = "<cmd>Git push<CR>";
    options = {
      desc = "Git Push";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>gpf";
    action = "<cmd>Git pfl<CR>";
    options = {
      desc = "Git Push --force-with-lease";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>gpF";
    action = "<cmd>Git push --force<CR>";
    options = {
      desc = "Git Push --force";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>gPP";
    action = "<cmd>Octo pr create<CR>";
    options = {
      desc = "Create Github PR";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>gPb";
    action = "<cmd>Octo pr browser<CR>";
    options = {
      desc = "Open Github PR in your browser";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>gPm";
    action = "<cmd>Octo pr merge<CR>";
    options = {
      desc = "Merge the PR";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>gPl";
    action = "<cmd>Octo pr list<CR>";
    options = {
      desc = "List PRs";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>gPl";
    action = "<cmd>Octo pr list<CR>";
    options = {
      desc = "List PRs";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>gPR";
    action = "<cmd>Octo pr reload<CR>";
    options = {
      desc = "Reload PR";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>gPr";
    action = "<cmd>Octo pr ready<CR>";
    options = {
      desc = "Mark PR as ready for review";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>gPs";
    action = "<cmd>Octo pr search<CR>";
    options = {
      desc = "Search PRs";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>gPd";
    action = "<cmd>Octo pr diff<CR>";
    options = {
      desc = "Diff PR";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>gPD";
    action = "<cmd>Octo pr draft<CR>";
    options = {
      desc = "Convert PR to draft";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>gPe";
    action = "<cmd>Octo pr edit<CR>";
    options = {
      desc = "Edit PR";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>gPc";
    action = "<cmd>Octo pr checks<CR>";
    options = {
      desc = "PR checks status";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>gPo";
    action = "<cmd>Octo pr checkout<CR>";
    options = {
      desc = "Checkout PR branch";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>gPO";
    action = "<cmd>Octo pr commits<CR>";
    options = {
      desc = "List PR commits";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>gPC";
    action = "<cmd>Octo pr close<CR>";
    options = {
      desc = "Close PR";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>gPC";
    action = "<cmd>Octo pr reopen<CR>";
    options = {
      desc = "Reopen PR";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>gPu";
    action = "<cmd>Octo pr url<CR>";
    options = {
      desc = "Copy PR URL to clipboard";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>gwc";
    action = "<cmd>Telescope git_worktree create_git_worktree<CR>";
    options = {
      desc = "Create Git Worktree";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>gws";
    action = "<cmd>Telescope git_worktree git_worktrees<CR>";
    options = {
      desc = "Open Git Worktrees in Telescope";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>gy";
    action = "<cmd>lua require('gitlinker').get_buf_range_url('n')<CR>";
    options = {
      desc = "Copy link to current line";
      silent = true;
    };
  }
]
