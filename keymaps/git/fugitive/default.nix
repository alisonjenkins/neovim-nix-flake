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
    key = "<leader>gfF";
    action = "<cmd>Git fetch origin<CR>";
    options = {
      desc = "Git fetch";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>gff";
    action = "<cmd>Git fetch origin --prune<CR>";
    options = {
      desc = "Git fetch prune";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>gfr";
    action = "<cmd>Git fetch --refetch<CR>";
    options = {
      desc = "Git fetch refetch";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>gft";
    action = "<cmd>Git fetch --tags<CR>";
    options = {
      desc = "Git fetch tags";
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
    key = "<leader>grr";
    action = ":Git rebase -i HEAD~<c-l>";
    options = {
      desc = "Git Rebase";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>grc";
    action = "<cmd>Git rebase --continue<CR>";
    options = {
      desc = "Git Rebase Continue";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>grm";
    action = "<cmd>Git rebase master<CR>";
    options = {
      desc = "Git Rebase master";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>grM";
    action = "<cmd>Git rebase main<CR>";
    options = {
      desc = "Git Rebase main";
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
    key = "<leader>gSS";
    action = "<cmd>Git stash<CR>";
    options = {
      desc = "Git Stash";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>gSs";
    action = "<cmd>Git stash<CR>";
    options = {
      desc = "Git Stash";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>gSt";
    action = "<cmd>Git stash --staged<CR>";
    options = {
      desc = "Git Stash staged";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>gST";
    action = "<cmd>Git stash --staged<CR>";
    options = {
      desc = "Git Stash staged";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>gSP";
    action = "<cmd>Git stash pop<CR>";
    options = {
      desc = "Git Stash pop";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>gSp";
    action = "<cmd>Git stash pop<CR>";
    options = {
      desc = "Git Stash pop";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>gt";
    action = "<cmd>Git tag<c-l>";
    options = {
      desc = "Git tag";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>gpp";
    action = "<cmd>Git! push<CR>";
    options = {
      desc = "Git Push";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>gpf";
    action = "<cmd>Git! pfl<CR>";
    options = {
      desc = "Git Push --force-with-lease";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>gpt";
    action = "<cmd>Git! push --tags<CR>";
    options = {
      desc = "Git Push --tags";
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
    key = "<leader>gu";
    action = "<cmd>Git pull<CR>";
    options = {
      desc = "Git pull";
      silent = true;
    };
  }
]
