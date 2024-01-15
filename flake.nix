{
  description = "Alison Jenkins's Neovim Flake";

  inputs.nixvim.url = "github:nix-community/nixvim";
  inputs.flake-utils.url = "github:numtide/flake-utils";

  outputs = { self, nixvim, flake-utils, }:
    let
      config = {
        colorscheme = "kanagawa";
        colorschemes.kanagawa.enable = true;
        editorconfig.enable = true;
        globals.localleader = ",";
        globals.mapleader = " ";
        luaLoader.enable = true;

        autoCmd = [{
          event = [ "TextYankPost" ];
          pattern = [ "*" ];
          command = "silent! lua vim.highlight.on_yank()";
        }];

        extraConfigLua = ''
          vim.loop.fs_mkdir(vim.o.backupdir, 750)
          vim.loop.fs_mkdir(vim.o.directory, 750)
          vim.loop.fs_mkdir(vim.o.undodir, 750)

          vim.o.backupdir = vim.fn.stdpath("data") .. "/backup"    -- set backup directory to be a subdirectory of data to ensure that backups are not written to git repos
          vim.o.directory = vim.fn.stdpath("data") .. "/directory" -- Configure 'directory' to ensure that Neovim swap files are not written to repos.
          vim.o.sessionoptions = vim.o.sessionoptions .. ",globals"
          vim.o.undodir = vim.fn.stdpath("data") .. "/undo" -- set undodir to ensure that the undofiles are not saved to git repos.
        '';

        options = {
          autoindent = true;
          backspace = "indent,eol,start";
          backup = true;
          cmdheight = 2;
          colorcolumn = "80";
          completeopt = "menu,menuone,noselect";
          conceallevel = 0;
          cursorline = true;
          expandtab = true;
          foldenable = true;
          foldexpr = "nvim_treesitter#foldexpr()";
          foldlevel = 5;
          foldmethod = "expr";
          ignorecase = true;
          laststatus = 3;
          mouse = "a";
          number = true;
          pumheight = 0;
          relativenumber = true;
          shiftwidth = 4;
          showtabline = 1;
          signcolumn = "yes";
          smartcase = true;
          tabstop = 4;
          termguicolors = true;
          timeoutlen = 300;
          undofile = true;
          updatetime = 300;
          wrap = false;
          writebackup = true;
        };

        keymaps = [
          {
            mode = "n";
            key = "<leader>;";
            options.silent = true;
            action = "<cmd>Alpha<CR>";
          }
          {
            mode = "n";
            key = "<leader>sb";
            options.silent = true;
            action = "<cmd>Telescope buffers<CR>";
          }
          {
            mode = "n";
            key = "<leader>sf";
            options.silent = true;
            action = "<cmd>Telescope find_files<CR>";
          }
          {
            mode = "n";
            key = "<leader>st";
            options.silent = true;
            action = "<cmd>Telescope live_grep<CR>";
          }
          {
            mode = "n";
            key = "<leader>sp";
            options.silent = true;
            action = "<cmd>Telescope projects<CR>";
          }
          {
            mode = "n";
            key = "<leader>f";
            options.silent = true;
            action = "<cmd>Telescope find_files<CR>";
          }
          {
            mode = "n";
            key = "<leader>r";
            options.silent = true;
            action = "<cmd>Telescope frecency<CR>";
          }
          {
            mode = "n";
            key = "<leader>ga";
            options.silent = true;
            action = "<cmd>Gwrite<CR>";
          }
          {
            mode = "n";
            key = "<leader>gb";
            options.silent = true;
            action = "<cmd>Telescope branches<CR>";
          }
          {
            mode = "n";
            key = "<leader>gl";
            options.silent = true;
            action = "<cmd>Git log<CR>";
          }
          {
            mode = "n";
            key = "<leader>gs";
            options.silent = true;
            action = "<cmd>Git<CR>";
          }
          {
            mode = "n";
            key = "<leader>gp";
            options.silent = true;
            action = "<cmd>Git push<CR>";
          }
          {
            mode = "n";
            key = "<leader>gll";
            options.silent = true;
            action = ''lua require"gitlinker".get_repo_url()<cr>'';
          }
          {
            mode = "n";
            key = "<leader>glb";
            options.silent = true;
            action = ''
              lua require"gitlinker".get_repo_url({action_callback = require"gitlinker.actions".open_in_browser})<cr>'';
          }
          {
            mode = "n";
            key = "-";
            options.silent = true;
            action = "<cmd>Oil<cr>";
          }
          {
            mode = "n";
            key = "[b";
            options.silent = true;
            action = "<cmd>BufferPrevious<cr>";
          }
          {
            mode = "n";
            key = "[B";
            options.silent = true;
            action = "<cmd>BufferMovePrevious<cr>";
          }
          {
            mode = "n";
            key = "]b";
            options.silent = true;
            action = "<cmd>BufferNext<cr>";
          }
          {
            mode = "n";
            key = "]B";
            options.silent = true;
            action = "<cmd>BufferMoveNext<cr>";
          }
          {
            mode = "n";
            key = "<leader>bd";
            options.silent = true;
            action = "<cmd>BufferClose<cr>";
          }
          {
            mode = "n";
            key = "<leader>bp";
            options.silent = true;
            action = "<cmd>BufferPick<cr>";
          }
          {
            mode = "n";
            key = "<leader>zI";
            options.silent = true;
            action = "<cmd>ZkIndex<cr>";
          }
          {
            mode = "n";
            key = "<leader>ln";
            options.silent = true;
            action = "<cmd>Navbuddy<cr>";
          }
          {
            mode = "n";
            key = "<leader>zc";
            options.silent = true;
            action = "<cmd>ZkCd<cr>";
          }
          {
            mode = "n";
            key = "<leader>zn";
            options.silent = true;
            action = "<cmd>ZkNotes<cr>";
          }
          {
            mode = "n";
            key = "<leader>zN";
            options.silent = true;
            action = "<cmd>ZkNew<cr>";
          }
          {
            mode = "n";
            key = "<leader>zb";
            options.silent = true;
            action = "<cmd>ZkBacklinks<cr>";
          }
          {
            mode = "n";
            key = "<leader>zl";
            options.silent = true;
            action = "<cmd>ZkLinks<cr>";
          }
          {
            mode = "n";
            key = "<leader>zi";
            options.silent = true;
            action = "<cmd>ZkInsertLink<cr>";
          }
          {
            mode = "n";
            key = "<leader>zt";
            options.silent = true;
            action = "<cmd>ZkTags<cr>";
          }
          {
            mode = "n";
            key = "<leader>zo";
            options.silent = true;
            action =
              "<cmd>ZkNotes { sort = { 'modified' }, match = { vim.fn.input('Search: ') } }<cr>";
          }
        ];

        plugins = {

          comment-nvim.enable = true;
          fidget.enable = true;
          fugitive.enable = true;
          gitlinker.enable = true;
          gitsigns.enable = true;
          lastplace.enable = true;
          leap.enable = true;
          lspkind.enable = true;
          lualine.enable = true;
          molten.enable = true;
          navic.enable = true;
          nix.enable = true;
          noice.enable = true;
          notify.enable = false;
          nvim-osc52.enable = true;
          project-nvim.enable = true;
          rainbow-delimiters.enable = true;
          rust-tools.enable = true;
          tmux-navigator.enable = true;
          treesitter-context.enable = true;
          treesitter-refactor.enable = true;
          treesitter-textobjects.enable = true;
          ts-autotag.enable = true;
          ts-context-commentstring.enable = true;
          typst-vim.enable = true;
          wilder.enable = true;

          alpha = {
            enable = true;
            theme = "startify";
          };

          barbar = {
            enable = true;
            animation = true;
            autoHide = true;
          };

          conform-nvim = {
            enable = true;
            formattersByFt = {
              "*" = [ "codespell" ];
              "_" = [ "trim_whitespace" ];
              go = [ "goimports" "golines" "gofmt" "gofumpt" ];
              javascript = [[ "prettierd" "prettier" ]];
              json = [ "jq" ];
              lua = [ "stylua" ];
              nix = [ "nixfmt" ];
              python = [ "isort" "black" ];
              rust = [ "rustfmt" ];
              sh = [ "shfmt" ];
              terraform = [ "terraform_fmt" ];
            };

            formatOnSave = ''
              function(bufnr)
                local ignore_filetypes = { "helm" }
                if vim.tbl_contains(ignore_filetypes, vim.bo[bufnr].filetype) then
                  return
                end

                -- Disable with a global or buffer-local variable
                if vim.g.disable_autoformat or vim.b[bufnr].disable_autoformat then
                  return
                end

                -- Disable autoformat for files in a certain path
                local bufname = vim.api.nvim_buf_get_name(bufnr)
                if bufname:match("/node_modules/") then
                  return
                end
                return { timeout_ms = 500, lsp_fallback = true }
              end
            '';
          };

          copilot-cmp = {
            event = [ "InsertEnter" "LspAttach" ];
            fixPairs = true;
          };

          copilot-lua = {
            enable = true;
            panel.enabled = false;
            suggestion.enabled = false;
          };

          flash = {
            enable = true;
            search = {
              automatic = true;
              incremental = true;
            };
            jump = { autojump = true; };
            label.rainbow.enabled = true;
          };

          luasnip = {
            enable = true;
            # paths = [];
            # fromVscode = [];
          };

          nvim-cmp = {
            enable = true;
            autoEnableSources = true;

            mapping = {
              "<C-d>" = "cmp.mapping.scroll_docs(-4)";
              "<C-e>" = "cmp.mapping.abort()";
              "<C-f>" = "cmp.mapping.scroll_docs(4)";
              "<C-n>" =
                "cmp.mapping.select_next_item { behavior = cmp.SelectBehavior.Insert }";
              "<C-u>" = "cmp.mapping.complete({})";
              "<C-p>" =
                "cmp.mapping.select_prev_item { behavior = cmp.SelectBehavior.Insert }";
              "<C-y>" = ''
                cmp.mapping.confirm({ select = true, behavior = cmp.ConfirmBehavior.Insert }, {"i", "c"})'';
              "<C-space>" = ''
                cmp.mapping {
                  i = cmp.mapping.complete(),
                  c = function(
                    _ --[[fallback]]
                  )
                  if cmp.visible() then
                      if not cmp.confirm { select = true } then
                        return
                      end
                    else
                      cmp.complete()
                    end
                  end,
                }
              '';
              "<tab>" = "cmp.config.diable";
            };

            snippet = {
              expand.__raw = ''
                function(args)
                require("luasnip").lsp_expand(args.body)
                end
              '';
            };

            sources = [
              { name = "copilot"; }
              { name = "nvim_lsp"; }
              {
                name = "luasnip";
                option = { show_autosnippets = true; };
              }
              { name = "path"; }
              { name = "buffer"; }
            ];
          };

          navbuddy = {
            enable = true;
            lsp.autoAttach = true;
          };

          oil = {
            enable = true;
            deleteToTrash = true;
            viewOptions = { showHidden = true; };
            skipConfirmForSimpleEdits = true;
            useDefaultKeymaps = false;

            keymaps = {
              "g?" = "actions.show_help";
              "<CR>" = "actions.select";
              "-" = "actions.parent";
              "_" = "actions.open_cwd";
              "`" = "actions.cd";
              "~" = "actions.tcd";
              "g." = "actions.toggle_hidden";
            };
          };

          telescope = {
            enable = true;
            extensions = {
              frecency.enable = true;
              fzy-native.enable = true;
              project-nvim.enable = true;
            };
          };

          treesitter = {
            enable = true;
            incrementalSelection = { enable = true; };
          };

          which-key = {
            enable = true;
            registrations = {
              "<leader>s" = "Search using Telescope";
              "<leader>z" = "Zettelkasten";
            };
          };

          lsp = {
            enable = true;
            servers = {

              ansiblels.enable = true;
              bashls.enable = true;
              cssls.enable = true;
              docker.enable = true;
              gopls.enable = true;
              jsonls.enable = true;
              nil_ls.enable = true;
              nushell.enable = true;
              rnix-lsp.enable = true;
              terraformls.enable = true;

              rust-analyzer = {
                enable = true;
                installRustc = true;
                installCargo = true;
              };
            };
          };

          lspsaga = { enable = true; };

          zk = {
            enable = true;
            picker = "telescope";
          };

        };
      };
    in flake-utils.lib.eachDefaultSystem (system:
      let
        nixvim' = nixvim.legacyPackages."${system}";
        nvim = nixvim'.makeNixvim config;
      in {
        packages = {
          inherit nvim;
          default = nvim;
        };
      });
}
