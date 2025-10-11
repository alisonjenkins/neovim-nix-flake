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
    action = "<cmd>lua require('snacks').picker.git_branches({win = { input = { keys = { ['<c-g>'] = { 'git_branch_add', mode = { 'n', 'i' } } } } }})<CR>";
    options = {
      desc = "Branches";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>gco";
    action = "<cmd>GitConflictChooseOurs<CR>";
    options = {
      desc = "Git Conflict - Choose Ours";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>gct";
    action = "<cmd>GitConflictChooseTheirs<CR>";
    options = {
      desc = "Git Conflict - Choose Theirs";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>gcb";
    action = "<cmd>GitConflictChooseBoth<CR>";
    options = {
      desc = "Git Conflict - Choose Both";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>gcl";
    action = "<cmd>GitConflictListQf<CR>";
    options = {
      desc = "Git Conflict - List in Quickfix";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>gcj";
    action = "<cmd>GitConflictNextConflict<CR>";
    options = {
      desc = "Git Conflict - Next";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>gck";
    action = "<cmd>GitConflictPrevConflict<CR>";
    options = {
      desc = "Git Conflict - Previous";
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
    key = "<leader>gfF";
    action = "<cmd>Git fetch origin<CR>";
    options = {
      desc = "Git fetch";
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
    key = "<leader>gRo";
    action = "<cmd>lua require('snacks').gitbrowse()<CR>";
    options = {
      desc = "Open Git repo";
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
    key = "<leader>gT";
    action = "<cmd>Tardis git<CR>";
    options = {
      desc = "Git Time Travel for the current file using Tardis";
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
    key = "<leader>gy";
    action = "<cmd>lua require('snacks').get_url()<CR>";
    options = {
      desc = "Copy link to current line";
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
