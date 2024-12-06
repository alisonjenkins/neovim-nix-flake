{
  description = "Alison Jenkins's Neovim Flake";

  inputs = {
    flake-parts.url = "github:hercules-ci/flake-parts";
    neovim-nightly-overlay.url = "github:nix-community/neovim-nightly-overlay";
    nixpkgs-master.url = "github:nixos/nixpkgs";
    nixpkgs-stable.url = "github:nixos/nixpkgs/nixos-24.11";
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    nixvim.url = "github:nix-community/nixvim";
    treefmt-nix.url = "github:numtide/treefmt-nix";
  };

  outputs =
    { flake-parts
    , nixvim
    , ...
    } @ inputs:
    let
      config = { pkgs, ... }:
        {
          colorschemes = { melange = { enable = true; }; };
          editorconfig.enable = true;
          luaLoader.enable = true;
          package =
            inputs.neovim-nightly-overlay.packages.${pkgs.system}.default;

          autoCmd = [
            {
              event = [ "TextYankPost" ];
              pattern = [ "*" ];
              command = "silent! lua vim.highlight.on_yank()";
            }
            {
              event = [ "BufEnter" ];
              pattern = [ "github.com_*.txt" ];
              command = "set filetype=markdown";
            }
            {
              event = "FileType";
              pattern = "helm";
              command = "LspRestart";
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

            -- do
            --   local parser_config = require("nvim-treesitter.parsers").get_parser_configs()
            --
            --   parser_config.powershell = {
            --     install_info = {
            --       url = treesitter-powershell-grammar,
            --       files = {"src/parser.c"},
            --       filetype = "powershell",
            --     }
            --   }
            --
            --   parser_config.vhdl = {
            --     install_info = {
            --       url = treesitter-vhdl-grammar,
            --       files = {"src/parser.c"},
            --       filetype = "vhdl",
            --     }
            --   }
            --
            --   parser_config.vrl = {
            --     install_info = {
            --       url = treesitter-vrl-grammar,
            --       files = {"src/parser.c"},
            --       filetype = "vrl",
            --     }
            --   }
            -- end

            require('bamboo').setup({
              style = "multiplex",
              transparent = true,

              lualine = {
                transparent = true,
              };
            })
            require('bamboo').load()
            require('outline').setup({})

            local Hooks = require('git-worktree.hooks')
            local config = require('git-worktree.config')
            local update_on_switch = Hooks.builtins.update_current_buffer_on_switch

            Hooks.register(Hooks.type.SWITCH, function (path, prev_path)
            vim.notify('Moved from ' .. prev_path .. ' to ' .. path)
            update_on_switch(path, prev_path)
            end)

            Hooks.register(Hooks.type.DELETE, function ()
            vim.cmd(config.update_on_change_command)
            end)
            require('telescope').load_extension('git_worktree')
          '';

          extraFiles = {
            "ftplugin/java.lua".text = ''
              local config = {
                cmd = {'${pkgs.jdt-language-server}/bin/jdtls', '--jvm-arg=-javaagent:${pkgs.lombok}/share/java/lombok.jar', '--jvm-arg=-Xbootclasspath/a:${pkgs.lombok}/share/java/lombok.jar'},
                root_dir = vim.fs.dirname(vim.fs.find({'gradlew', '.git', 'mvnw'}, { upward = true })[1]),
              }
              require('jdtls').start_or_attach(config)
            '';
            "ftplugin/lua.lua".text = ''
              local lazydev = require('lazydev')
              lazydev.setup({
                enabled = true
              })

              lazydev.find_workspace(buf)
            '';
          };

          extraPackages = with pkgs; [
            # alejandra
            (python3.withPackages (python-pkgs: [ python-pkgs.pylatexenc ]))
            black
            gofumpt
            golangci-lint
            golines
            isort
            jq
            lldb
            nixpkgs-fmt
            nodePackages.prettier
            prettierd
            rustfmt
            shfmt
            stylua
          ];

          extraPlugins = with pkgs.vimPlugins; [
            bamboo-nvim
            git-worktree-nvim
            lazydev-nvim
            nvim-jdtls
            outline-nvim
            vim-table-mode
          ];

          extraPython3Packages = p: [ p.numpy p.plotly p.pnglatex p.pyperclip ];

          globals = {
            localleader = ",";
            mapleader = " ";
            markdown_folding = true;
          };

          opts = {
            autoindent = true;
            backspace = "indent,eol,start";
            backup = true;
            cmdheight = 2;
            completeopt = "menu,menuone,noselect";
            conceallevel = 0;
            cursorline = true;
            expandtab = true;
            foldcolumn = "1";
            foldenable = true;
            foldlevel = 5;
            foldlevelstart = 99;
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

          keymaps =
            [
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
              {
                mode = "n";
                key = "zR";
                action = "<cmd>lua require('ufo').openAllFolds()<cr>";
                options = {
                  desc = "Open all folds";
                  silent = true;
                };
              }
              {
                mode = "n";
                key = "zM";
                action = "<cmd>lua require('ufo').closeAllFolds()<cr>";
                options = {
                  desc = "Close all folds";
                  silent = true;
                };
              }
            ]
            ++ import ./keymaps/buffers
            ++ import ./keymaps/debugging
            ++ import ./keymaps/git
            ++ import ./keymaps/harpoon
            ++ import ./keymaps/lsp
            ++ import ./keymaps/rust-lsp
            ++ import ./keymaps/search
            ++ import ./keymaps/testing
            ++ import ./keymaps/zk;

          performance = {
            byteCompileLua.enable = true;
            combinePlugins.enable = false;
          };

          plugins = {
            # image.enable = true;
            bacon.enable = true;
            bufdelete.enable = true;
            ccc.enable = true;
            cmp-cmdline.enable = true;
            cmp-dap.enable = true;
            cmp-nvim-lsp.enable = true;
            comment.enable = true;
            committia.enable = true;
            direnv.enable = true;
            earthly.enable = true;
            fidget.enable = true;
            friendly-snippets.enable = true;
            fugitive.enable = true;
            gitignore.enable = true;
            gitsigns.enable = true;
            hardtime.enable = false;
            helm.enable = true;
            helpview.enable = true;
            hmts.enable = true;
            indent-blankline.enable = true;
            lastplace.enable = true;
            lspkind.enable = true;
            lspsaga.enable = true;
            markdown-preview.enable = true;
            molten.enable = true;
            navic.enable = true;
            nix.enable = true;
            numbertoggle.enable = true;
            nvim-ufo.enable = true;
            rainbow-delimiters.enable = true;
            render-markdown.enable = true;
            schemastore.enable = true;
            sleuth.enable = true;
            specs.enable = false;
            tmux-navigator.enable = true;
            treesitter-refactor.enable = true;
            treesitter-textobjects.enable = true;
            ts-autotag.enable = true;
            ts-context-commentstring.enable = true;
            typst-vim.enable = true;
            vim-be-good.enable = true;
            vim-css-color.enable = true;
            web-devicons.enable = true;
            wilder.enable = true;
            wrapping.enable = true;
            zig.enable = true;
          }
          // (
            (import ./plugin-config/alpha)
              // (import ./plugin-config/arrow)
              // (import ./plugin-config/cmp)
              // (import ./plugin-config/codecompanion)
              // (import ./plugin-config/conform-nvim)
              // (import ./plugin-config/crates-nvim)
              // (import ./plugin-config/dap { inherit pkgs; })
              // (import ./plugin-config/firenvim)
              // (import ./plugin-config/git-linker)
              // (import ./plugin-config/harpoon)
              // (import ./plugin-config/leap)
              // (import ./plugin-config/lsp)
              // (import ./plugin-config/lualine)
              // (import ./plugin-config/luasnip)
              // (import ./plugin-config/mini)
              // (import ./plugin-config/navbuddy)
              // (import ./plugin-config/neorg { inherit pkgs; })
              // (import ./plugin-config/neotest)
              // (import ./plugin-config/noice { inherit pkgs; })
              // (import ./plugin-config/notify)
              // (import ./plugin-config/octo)
              // (import ./plugin-config/oil)
              // (import ./plugin-config/project-nvim)
              // (import ./plugin-config/rustaceanvim { inherit pkgs; })
              // (import ./plugin-config/smartcolumn)
              // (import ./plugin-config/telescope)
              // (import ./plugin-config/treesitter { inherit pkgs; })
              // (import ./plugin-config/treesitter-context)
              // (import ./plugin-config/trouble)
              // (import ./plugin-config/which-key)
              // (import ./plugin-config/zk)
          );
        };
    in
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "aarch64-darwin" "aarch64-linux" "x86_64-darwin" "x86_64-linux" ];

      imports = [ inputs.treefmt-nix.flakeModule ];

      perSystem =
        { pkgs
        , system
        , ...
        }:
        let
          nixvimLib = nixvim.lib.${system};
          nixvim' = nixvim.legacyPackages.${system};
          nvim = nixvim'.makeNixvimWithModule {
            inherit pkgs;
            module = config;
            extraSpecialArgs = { };
          };
        in
        {
          _module.args.pkgs = import inputs.nixpkgs {
            inherit system;
            overlays = [
              (final: _prev: {
                master = import inputs.nixpkgs-master {
                  system = final.system;
                  config.allowUnfree = true;
                };
              })
              (final: _prev: {
                stable = import inputs.nixpkgs-stable {
                  system = final.system;
                  config.allowUnfree = true;
                };
              })
              (final: prev: {
                vimPlugins = prev.vimPlugins.extend (vfinal: vprev: {
                  git-worktree-nvim = vprev.git-worktree-nvim.overrideAttrs (oldAttrs: {
                    src = prev.fetchFromGitHub {
                      owner = "polarmutex";
                      repo = "git-worktree.nvim";
                      rev = "bac72c240b6bf1662296c31546c6dad89b4b7a3c";
                      hash = "sha256-Uvcihnc/+v4svCrAO2ds0XvNmqO801ILWu8sbh/znf4=";
                    };
                  });
                  # fastaction-nvim = vprev.fastaction-nvim.overrideAttrs (oldAttrs: {
                  #   src = prev.fetchFromGitHub {
                  #     owner = "alisonjenkins";
                  #     repo = "fastaction.nvim";
                  #     rev = "b0e72626135b703fe186a062f38a47ac739f1cdd";
                  #     hash = "sha256-1HXIssBemCB7asQE6L7XiqGQC0gzwqIXhSollk2DV2o=";
                  #   };
                  # });
                  neotest-zig = vprev.neotest-zig.overrideAttrs (oldAttrs: {
                    src = prev.fetchFromGitHub {
                      owner = "lawrence-laz";
                      repo = "neotest-zig";
                      rev = "b0e72626135b703fe186a062f38a47ac739f1cdd";
                      hash = "sha256-1HXIssBemCB7asQE6L7XiqGQC0gzwqIXhSollk2DV2o=";
                    };
                  });
                  zk-nvim = vprev.zk-nvim.overrideAttrs (oldAttrs: {
                    src = prev.fetchFromGitHub {
                      owner = "alisonjenkins";
                      repo = "zk-nvim";
                      rev = "c9a073cb16b3514cdce5e1a84c6996989e79630f";
                      hash = "sha256-WhiwPsABFISzOlZuZYR7W2D2q4pD6VGqjIyqcrO05rc=";
                    };
                  });
                });
              })
            ];
            config = { };
          };

          checks = {
            default = nixvimLib.check.mkTestDerivationFromNvim {
              inherit nvim;
              name = "A nixvim configuration";
            };
          };

          packages = {
            default = nvim;
            nvim = nvim;
          };

          treefmt = {
            projectRootFile = "flake.nix";
            programs.nixpkgs-fmt.enable = true;
          };
        };
    };
}
