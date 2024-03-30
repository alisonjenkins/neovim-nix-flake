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

        opts = {
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
            key = "K";
            action = "<cmd>Lspsaga hover_doc<CR>";
            options = {
              desc = "Show docs for hovered item.";
              silent = true;
            };
          }
          {
            mode = "n";
            key = "<leader>;";
            action = "<cmd>Alpha<CR>";
            options = {
              desc = "Open Alpha (Splash Screen)";
              silent = true;
            };
          }
          {
            mode = "n";
            key = "<leader>f";
            action = "<cmd>Telescope find_files<CR>";
            options = {
              desc = "Find files using Telescope";
              silent = true;
            };
          }
          {
            mode = "n";
            key = "<leader>r";
            action = "<cmd>Telescope frecency<CR>";
            options = {
              desc = "Find frecently used files";
              silent = true;
            };
          }
          {
            mode = "n";
            key = "-";
            action = "<cmd>Oil<cr>";
            options = {
              desc = "Open File Browser in current directory";
              silent = true;
            };
          }
          {
            mode = "n";
            key = "[b";
            action = "<cmd>BufferPrevious<cr>";
            options = {
              desc = "Open previous buffer";
              silent = true;
            };
          }
          {
            mode = "n";
            key = "[B";
            action = "<cmd>BufferMovePrevious<cr>";
            options = {
              desc = "Move buffer back in list";
              silent = true;
            };
          }
          {
            mode = "n";
            key = "]b";
            action = "<cmd>BufferNext<cr>";
            options = {
              desc = "Move to next buffer";
              silent = true;
            };
          }
          {
            mode = "n";
            key = "]B";
            action = "<cmd>BufferMoveNext<cr>";
            options = {
              desc = "Move buffer forward in list";
              silent = true;
            };
          }
          {
            mode = "n";
            key = "]d";
            action = "<cmd>Lspsaga diagnostic_jump_next<cr>";
            options = {
              desc = "Jump to next diagnostic";
              silent = true;
            };
          }
          {
            mode = "n";
            key = "[d";
            action = "<cmd>Lspsaga diagnostic_jump_prev<cr>";
            options = {
              desc = "Jump to previous diagnostic";
              silent = true;
            };
          }
          {
            mode = "n";
            key = "[r";
            action = "<cmd>BaconPrevious<cr>";
            options = {
              desc = "Bacon Previous Issue";
              silent = true;
            };
          }
          {
            mode = "n";
            key = "]r";
            action = "<cmd>BaconNext<cr>";
            options = {
              desc = "Bacon Next Issue";
              silent = true;
            };
          }
          {
            mode = "n";
            key = "gd";
            action = "<cmd>Lspsaga goto_definition<cr>";
            options = {
              desc = "Goto definition of highlighted item";
              silent = true;
            };
          }
          {
            mode = "n";
            key = "gD";
            action = "<cmd>Lspsaga goto_type_definition<cr>";
            options = {
              desc = "Goto type definition of highlighted item";
              silent = true;
            };
          }
        ]
        ++ import ./keymaps/buffers
        ++ import ./keymaps/git
        ++ import ./keymaps/harpoon
        ++ import ./keymaps/lsp
        ++ import ./keymaps/search
        ++ import ./keymaps/zk;

        plugins = {

          bacon.enable = true;
          comment.enable = true;
          committia.enable = true;
          direnv.enable = true;
          fidget.enable = true;
          friendly-snippets.enable = true;
          fugitive.enable = true;
          gitlinker.enable = false;
          gitsigns.enable = true;
          headlines.enable = true;
          helm.enable = true;
          hmts.enable = true;
          indent-blankline.enable = true;
          indent-o-matic.enable = true;
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
          specs.enable = true;
          tmux-navigator.enable = true;
          treesitter-refactor.enable = true;
          treesitter-textobjects.enable = true;
          ts-autotag.enable = true;
          ts-context-commentstring.enable = true;
          typst-vim.enable = true;
          virt-column.enable = true;
          wilder.enable = true;
          zig.enable = true;

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
              javascript = [ [ "prettierd" "prettier" ] ];
              json = [ "jq" ];
              lua = [ "stylua" ];
              nix = [ "alejandra" ];
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

          git-worktree = {
            enable = true;
            enableTelescope = true;
            changeDirectoryCommand = "tcd";
          };

          harpoon = {
            enable = true;
            enableTelescope = true;
          };

          luasnip = {
            enable = true;
            # paths = [];
            # fromVscode = [];
          };

          cmp = {
            enable = true;
            autoEnableSources = true;

            settings = {
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
                expand = ''
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
          };

          navbuddy = {
            enable = true;
            lsp.autoAttach = true;
          };

          oil = {
            enable = true;

            settings = {
              delete_to_trash = true;
              skip_confirm_for_simple_edits = true;
              use_default_keymaps = false;

              keymaps = {
                "g?" = "actions.show_help";
                "<CR>" = "actions.select";
                "-" = "actions.parent";
                "_" = "actions.open_cwd";
                "`" = "actions.cd";
                "~" = "actions.tcd";
                "g." = "actions.toggle_hidden";
              };

              view_options = {
                show_hidden = true; 
              };
            };

          };

          project-nvim = {
            enableTelescope = true;
          };

          rustaceanvim = {
            enable = false;

            server.settings = {
              files = {
                excludeDirs = [ ".direnv" ];
              };
            };
          };

          telescope = {
            enable = true;
            extensions = {
              frecency.enable = true;
              fzy-native.enable = true;
            };
          };

          treesitter = {
            enable = true;
            incrementalSelection = { enable = true; };
          };

          treesitter-context = {
            enable = true;
            extraOptions = {
              max_lines = 4;
            };
          };

          which-key = {
            enable = true;
            registrations = {
              "<leader>b" = "Buffers";
              "<leader>g" = "Git";
              "<leader>gp" = "Git Push";
              "<leader>h" = "Harpoon";
              "<leader>l" = "LSP";
              "<leader>lb" = "Bacon";
              "<leader>lf" = "LSP Finder";
              "<leader>lp" = "LSP Peek";
              "<leader>s" = "Search using Telescope";
              "<leader>z" = "Zettelkasten";
            };
          };

          lsp = {
            enable = true;
            servers = {

              ansiblels.enable = true;
              bashls.enable = true;
              ccls.enable = true;
              cssls.enable = true;
              dockerls.enable = true;
              gopls.enable = true;
              helm-ls.enable = true;
              html.enable = true;
              java-language-server.enable = true;
              jsonls.enable = true;
              lua-ls.enable = true;
              nil_ls.enable = true;
              nushell.enable = true;
              pylsp.enable = true;
              pylyzer.enable = false;
              ruff-lsp.enable = true;
              tailwindcss.enable = true;
              terraformls.enable = true;
              tsserver.enable = true;
              yamlls.enable = true;
              zls.enable = false;

              rust-analyzer = {
                enable = true;
                installRustc = true;
                installCargo = true;

                settings = {
                  files = {
                    excludeDirs = [ ".direnv" ];
                  };
                };
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
    in
    flake-utils.lib.eachDefaultSystem (system:
      let
        nixvim' = nixvim.legacyPackages."${system}";
        nvim = nixvim'.makeNixvim config;
      in
      {
        packages = {
          inherit nvim;
          default = nvim;
        };
      });
}
