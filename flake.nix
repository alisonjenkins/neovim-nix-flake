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
          colorschemes.melange.enable = true;
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
            {
              event = [ "BufRead" "BufNewFile" ];
              pattern = [ "*.tf" " *.tfvars" " *.hcl" ];
              command = "set filetype=terraform";
            }
            {
              event = [ "BufRead" ];
              pattern = [ "Cargo.toml" ];
              command = ''
                    vim.api.nvim_create_autocmd("BufRead", {
                    group = vim.api.nvim_create_augroup("CmpSourceCargo", { clear = true }),
                    pattern = "Cargo.toml",
                    callback = function()
                        cmp.setup.buffer({ sources = { { name = "crates" } } })
                    end,
                })
              '';
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

            local blink_compat = require('blink.compat')
            blink_compat.setup({})
            require'telescope'.load_extension('project')
          '';

          extraFiles = {
            "ftplugin/http.lua".text = import ./ftplugin/http.lua.nix;
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
            # lldb
            nixpkgs-fmt
            nodePackages.prettier
            prettierd
            rust-analyzer
            rustfmt
            shfmt
            stylua
          ];

          extraPlugins = with pkgs.vimPlugins; [
            bamboo-nvim
            blink-compat
            git-worktree-nvim
            lazydev-nvim
            nvim-jdtls
            outline-nvim
            telescope-project-nvim
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

          keymaps = [ ]
            ++ import ./keymaps/buffers
            ++ import ./keymaps/debugging
            ++ import ./keymaps/folding
            ++ import ./keymaps/git
            ++ import ./keymaps/harpoon
            ++ import ./keymaps/jumps
            ++ import ./keymaps/lsp
            ++ import ./keymaps/notifications
            ++ import ./keymaps/rust-lsp
            ++ import ./keymaps/search
            ++ import ./keymaps/tabs
            ++ import ./keymaps/terminal
            ++ import ./keymaps/testing
            ++ import ./keymaps/zk;

          performance = {
            byteCompileLua.enable = true;
          };

          plugins = {
            # image.enable = true;
            bacon.enable = true;
            bufdelete.enable = true;
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
            sleuth.enable = true;
            smear-cursor.enable = true;
            specs.enable = false;
            tmux-navigator.enable = true;
            neoscroll.enable = true;
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
              // (import ./plugin-config/blink-cmp { inherit pkgs; })
              // (import ./plugin-config/blink-cmp-git)
              // (import ./plugin-config/blink-cmp-dictionary)
              // (import ./plugin-config/blink-copilot)
              // (import ./plugin-config/blink-ripgrep)
              // (import ./plugin-config/ccc)
              // (import ./plugin-config/codecompanion)
              // (import ./plugin-config/conform-nvim)
              // (import ./plugin-config/copilot-lua)
              // (import ./plugin-config/crates)
              // (import ./plugin-config/dap { inherit pkgs; })
              // (import ./plugin-config/dap-go { inherit pkgs; })
              // (import ./plugin-config/dap-lldb { inherit pkgs; })
              // (import ./plugin-config/dap-python)
              // (import ./plugin-config/dap-ui)
              // (import ./plugin-config/dap-virtual-text)
              // (import ./plugin-config/firenvim)
              // (import ./plugin-config/git-linker)
              // (import ./plugin-config/harpoon)
              // (import ./plugin-config/kulala { inherit pkgs; })
              // (import ./plugin-config/lazydev)
              // (import ./plugin-config/leap)
              // (import ./plugin-config/lsp)
              // (import ./plugin-config/lualine)
              // (import ./plugin-config/luasnip)
              // (import ./plugin-config/lz-n)
              // (import ./plugin-config/mini)
              // (import ./plugin-config/navbuddy)
              // (import ./plugin-config/neorg { inherit pkgs; })
              // (import ./plugin-config/neotest)
              // (import ./plugin-config/noice { inherit pkgs; })
              // (import ./plugin-config/notify)
              // (import ./plugin-config/octo)
              // (import ./plugin-config/oil)
              // (import ./plugin-config/otter)
              // (import ./plugin-config/parinfer-rust)
              // (import ./plugin-config/remote-nvim { inherit pkgs; })
              // (import ./plugin-config/rustaceanvim { inherit pkgs; })
              // (import ./plugin-config/schemastore)
              // (import ./plugin-config/smartcolumn)
              // (import ./plugin-config/tailwind-tools)
              // (import ./plugin-config/telescope)
              // (import ./plugin-config/tiny-devicons-auto-colors)
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
        , self
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
          _module.args.pkgs = import self.inputs.nixpkgs {
            inherit system;
            config.allowUnfree = true;
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
                });
              })
            ];
            config.allowUnfree = true;
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

          devShells = {
            default = pkgs.mkShell {
              buildInputs = with pkgs; [
                just
                nix-fast-build
              ];

              shellHook = ''
                if [ -z ''${CACHIX_AUTH_TOKEN+x} ]; then 
                  echo "CACHIX_AUTH_TOKEN is unset";
                  CACHIX_AUTH_TOKEN=''$(${pkgs._1password-cli}/bin/op item get "Cachix Token" --fields label=password --reveal)
                fi
              '';
            };
          };
        };
    };
}
