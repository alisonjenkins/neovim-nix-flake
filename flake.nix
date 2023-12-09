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

        autoCmd = [
          {
            event = ["TextYankPost"];
            pattern = ["*"];
            command = "silent! lua vim.highlight.on_yank()";
          }
        ];

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
            action = ''<cmd>Oil<cr>'';
          }
        ];

        plugins = {

          # flash.enable = true;
          # nvim-navbudy.enable = true;
          barbar.enable = true;
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
          nix.enable = true;
          noice.enable = true;
          notify.enable = true;
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

          # alpha = {
          #   enable = true;
          #   iconsEnabled = true;
          #
          # };

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
          };

          copilot-cmp = {
            event = ["InsertEnter" "LspAttach" ];
            fixPairs = true;
          };

          copilot-lua = {
            enable = true;
            panel.enabled = false;
            suggestion.enabled = false;
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
              "<C-b>" = "cmp.mapping.scroll_docs(-4)";
              "<C-f>" = "cmp.mapping.scroll_docs(4)";
              "<C-o>" = "cmp.mapping.complete({})";
              "<C-e>" = "cmp.mapping.abort()";
              "<C-y>" = "cmp.mapping.confirm({ select = true })";
            };

            snippet = {
              expand.__raw = ''
              function(args)
              require("luasnip").lsp_expand(args.body)
              end
              '';
            };

            sources = [
              {name = "copilot";}
              {name = "nvim_lsp";}
              {
                name = "luasnip";
                option = {
                  show_autosnippets = true;
                };
              }
              {name = "path";}
              {name = "buffer";}
            ];
          };

          oil = {
            enable = true;
            deleteToTrash = true;
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
            registrations = { "<leader>s" = "Search using Telescope"; };
          };

          lsp = {
            enable = true;
            servers = {

              nil_ls.enable = true;
              rnix-lsp.enable = true;
              jsonls.enable = true;

              rust-analyzer = {
                enable = true;
                installRustc = true;
                installCargo = true;
              };
            };
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
