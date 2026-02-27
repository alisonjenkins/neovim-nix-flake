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
    action = "<cmd>GitFetchSilent origin<CR>";
    options = {
      desc = "Git fetch";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>gff";
    action = "<cmd>GitFetchSilent origin --prune<CR>";
    options = {
      desc = "Git fetch prune";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>gfr";
    action = "<cmd>GitFetchSilent --refetch<CR>";
    options = {
      desc = "Git fetch refetch";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>gft";
    action = "<cmd>GitFetchSilent --tags<CR>";
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
    action.__raw = ''
      function()
        local branch = vim.trim(vim.fn.system("git rev-parse --abbrev-ref origin/HEAD 2>/dev/null"))
        if vim.v.shell_error ~= 0 or branch == "" then
          branch = "main"
        end
        branch = branch:gsub("^origin/", "")
        vim.cmd("!git fetch origin " .. branch .. ":" .. branch .. " && git rebase --autostash" .. branch)
      end
    '';
    options = {
      desc = "Git Rebase against default branch";
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
    action = "<cmd>GitPushSilent<CR>";
    options = {
      desc = "Git Push";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>gpf";
    action = "<cmd>GitPushForceLeaseSilent<CR>";
    options = {
      desc = "Git Push --force-with-lease";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>gpt";
    action = "<cmd>GitPushTagsSilent<CR>";
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
