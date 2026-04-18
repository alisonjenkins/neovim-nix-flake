[
  {
    mode = "n";
    key = "<leader>sb";
    action = "<cmd>lua require('snacks').picker.buffers()<CR>";
    options = {
      desc = "Buffers";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>sB";
    action = "<cmd>require('snacks').picker.git_branches()<CR>";
    options = {
      desc = "Git Branches";
      silent = true;
    };
  }
  # {
  #   mode = "n";
  #   key = "<leader>se";
  #   action = "<cmd>Telescope file_browser<CR>";
  #   options = {
  #     desc = "Explore files (File Browser)";
  #     silent = true;
  #   };
  # }
  {
    mode = "n";
    key = "<leader>f";
    action = "<cmd>lua require('snacks').picker.files()<CR>";
    options = {
      desc = "Find Files";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>sf";
    action = "<cmd>lua require('snacks').picker.files()<CR>";
    options = {
      desc = "Files";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>sr";
    action = "<cmd>lua require('snacks').picker.recent()<CR>";
    options = {
      desc = "Find recently edited files";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>sh";
    action = "<cmd>lua require('snacks').picker.help()<CR>";
    options = {
      desc = "Help tags";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>ss";
    action = "<cmd>Tv<CR>";
    options = {
      desc = "Search TV channels";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>st";
    action = "<cmd>lua require('snacks').picker.grep()<CR>";
    options = {
      desc = "Live Grep";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>sp";
    action.__raw = ''
      function()
        require('snacks').picker.zoxide({
          actions = {
            oil_open = function(picker, item)
              if item then
                picker:close()
                vim.cmd('Oil ' .. vim.fn.fnameescape(item.file))
              end
            end,
          },
          confirm = function(picker, item)
            if not item then return end
            picker:close()
            vim.schedule(function()
            require('snacks').picker.files({
              cwd = item.file,
              actions = {
                oil_open_cwd = function(p)
                  local cwd = p:cwd()
                  p:close()
                  vim.cmd('Oil ' .. vim.fn.fnameescape(cwd))
                end,
                tcd_cwd = function(p)
                  local cwd = p:cwd()
                  p:close()
                  vim.cmd('tcd ' .. vim.fn.fnameescape(cwd))
                end,
              },
              win = {
                input = {
                  keys = {
                    ['<c-e>'] = { 'oil_open_cwd', mode = { 'n', 'i' }, desc = 'Open in Oil' },
                    ['<c-g>'] = { 'tcd_cwd', mode = { 'n', 'i' }, desc = 'Change directory' },
                  },
                },
              },
            })
            end)
          end,
          win = {
            input = {
              keys = {
                ['<c-e>'] = { 'oil_open', mode = { 'n', 'i' }, desc = 'Open in Oil' },
                ['<c-g>'] = { 'tcd', mode = { 'n', 'i' }, desc = 'Change directory' },
              },
            },
          },
        })
      end
    '';
    options = {
      desc = "Search for projects via zoxide";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>sl";
    action = "<cmd>lua require('snacks').picker.lines()<CR>";
    options = {
      desc = "Lines in current file";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>sz";
    action.__raw = ''
      function()
        require('snacks').picker.zoxide({
          actions = {
            oil_open = function(picker, item)
              if item then
                picker:close()
                vim.cmd('Oil ' .. vim.fn.fnameescape(item.file))
              end
            end,
          },
          confirm = function(picker, item)
            if not item then return end
            picker:close()
            vim.schedule(function()
            require('snacks').picker.files({
              cwd = item.file,
              actions = {
                oil_open_cwd = function(p)
                  local cwd = p:cwd()
                  p:close()
                  vim.cmd('Oil ' .. vim.fn.fnameescape(cwd))
                end,
                tcd_cwd = function(p)
                  local cwd = p:cwd()
                  p:close()
                  vim.cmd('tcd ' .. vim.fn.fnameescape(cwd))
                end,
              },
              win = {
                input = {
                  keys = {
                    ['<c-e>'] = { 'oil_open_cwd', mode = { 'n', 'i' }, desc = 'Open in Oil' },
                    ['<c-g>'] = { 'tcd_cwd', mode = { 'n', 'i' }, desc = 'Change directory' },
                  },
                },
              },
            })
            end)
          end,
          win = {
            input = {
              keys = {
                ['<c-e>'] = { 'oil_open', mode = { 'n', 'i' }, desc = 'Open in Oil' },
                ['<c-g>'] = { 'tcd', mode = { 'n', 'i' }, desc = 'Change directory' },
              },
            },
          },
        })
      end
    '';
    options = {
      desc = "Search for projects via zoxide";
      silent = true;
    };
  }
  # Search highlighting controls (AV optimization - hlsearch disabled by default)
  {
    mode = "n";
    key = "<leader>sH";
    action = "<cmd>set hlsearch!<CR>";
    options = {
      desc = "Toggle search highlighting";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<Esc>";
    action = "<cmd>nohlsearch<CR>";
    options = {
      desc = "Clear search highlighting";
      silent = true;
    };
  }
]
