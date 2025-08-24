{
  description = "Alison Jenkins's Neovim Flake";

  inputs = {
    flake-parts.url = "github:hercules-ci/flake-parts";
    # neovim-nightly-overlay.url = "github:nix-community/neovim-nightly-overlay";
    nixpkgs-master.url = "github:nixos/nixpkgs";
    nixpkgs-stable.url = "github:nixos/nixpkgs/nixos-24.11";
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    nixvim.url = "github:nix-community/nixvim";
    # nixvim.url = "github:alisonjenkins/nixvim/add-bamboo-colourscheme";
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
          editorconfig.enable = true;
          enableMan = false;
          luaLoader.enable = true;
          # package =
          #   inputs.neovim-nightly-overlay.packages.${pkgs.system}.default;

          autoCmd = [
            {
              event = [ "TextYankPost" ];
              pattern = [ "*" ];
              command = "silent! lua vim.hl.on_yank()";
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
            vim.o.backupdir = vim.fn.stdpath("data") .. "/backup"    -- set backup directory to be a subdirectory of data to ensure that backups are not written to git repos
            vim.o.directory = vim.fn.stdpath("data") .. "/directory" -- Configure 'directory' to ensure that Neovim swap files are not written to repos.
            vim.o.sessionoptions = vim.o.sessionoptions .. ",globals"
            vim.o.undodir = vim.fn.stdpath("data") .. "/undo" -- set undodir to ensure that the undofiles are not saved to git repos.
            vim.loop.fs_mkdir(vim.o.backupdir, 750)
            vim.loop.fs_mkdir(vim.o.directory, 750)
            vim.loop.fs_mkdir(vim.o.undodir, 750)
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
            # lldb
            (python3.withPackages (python-pkgs: [ python-pkgs.pylatexenc ]))
            black
            cowsay
            dwt1-shell-color-scripts
            fortune
            ghostscript
            gofumpt
            golangci-lint
            golines
            grpcurl
            imagemagick
            isort
            jq
            jupyter
            mermaid-cli
            nixpkgs-fmt
            nodePackages.prettier
            openssl
            postgresql
            prettierd
            rust-analyzer
            rustfmt
            shfmt
            sqlite
            stylua
            tectonic
            terraform
            websocat
            wordnet
          ];

          extraPlugins = with pkgs.vimPlugins; [
            lazydev-nvim
            nvim-jdtls
            vim-dadbod
            vim-dadbod-completion
            vim-dadbod-ui
            vim-table-mode
          ];

          extraPython3Packages = p: [
            p.ipykernel
            p.jupyter-client
            p.numpy
            p.plotly
            p.pnglatex
            p.pynvim
            p.pyperclip
          ];

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
            ++ import ./keymaps/ai/avante
            ++ import ./keymaps/ai/codecompanion
            ++ import ./keymaps/buffers
            ++ import ./keymaps/db
            ++ import ./keymaps/debugging
            ++ import ./keymaps/folding
            ++ import ./keymaps/git
            ++ import ./keymaps/harpoon
            ++ import ./keymaps/jumps
            ++ import ./keymaps/lsp
            ++ import ./keymaps/notifications
            ++ import ./keymaps/obsidian
            ++ import ./keymaps/rust-lsp
            ++ import ./keymaps/search
            ++ import ./keymaps/tabs
            ++ import ./keymaps/terminal
            ++ import ./keymaps/testing
            ++ import ./keymaps/zk;

          performance = {
            byteCompileLua = {
              enable = true;
              nvimRuntime = true;
              plugins = true;
            };
          };

          plugins = {
            # image.enable = true;
            bacon.enable = true;
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
            sleuth.enable = true;
            smear-cursor.enable = true;
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
            # (import ./plugin-config/alpha)
            (import ./plugin-config/arrow)
              // (import ./plugin-config/avante { inherit pkgs; })
              // (import ./plugin-config/blink-cmp { inherit pkgs; })
              // (import ./plugin-config/blink-cmp-copilot)
              // (import ./plugin-config/blink-cmp-dictionary)
              // (import ./plugin-config/blink-cmp-git)
              // (import ./plugin-config/blink-compat)
              // (import ./plugin-config/blink-ripgrep)
              // (import ./plugin-config/ccc)
              // (import ./plugin-config/codecompanion)
              // (import ./plugin-config/colorful-menu)
              // (import ./plugin-config/conform-nvim)
              // (import ./plugin-config/copilot-lua)
              // (import ./plugin-config/crates)
              // (import ./plugin-config/dap { inherit pkgs; })
              // (import ./plugin-config/dap-go { inherit pkgs; })
              // (import ./plugin-config/dap-lldb { inherit pkgs; })
              // (import ./plugin-config/dap-python)
              // (import ./plugin-config/dap-ui)
              // (import ./plugin-config/dap-virtual-text)
              // (import ./plugin-config/faster-nvim)
              // (import ./plugin-config/firenvim)
              // (import ./plugin-config/git-conflict)
              // (import ./plugin-config/harpoon)
              // (import ./plugin-config/img-clip { inherit  pkgs; })
              // (import ./plugin-config/indent-tools)
              // (import ./plugin-config/kulala { inherit pkgs; })
              // (import ./plugin-config/lazydev)
              // (import ./plugin-config/leap)
              // (import ./plugin-config/lsp { inherit  pkgs; })
              // (import ./plugin-config/lspkind)
              // (import ./plugin-config/lualine)
              // (import ./plugin-config/luasnip)
              // (import ./plugin-config/lz-n)
              // (import ./plugin-config/mini)
              // (import ./plugin-config/modicator)
              // (import ./plugin-config/navbuddy)
              // (import ./plugin-config/neorg { inherit pkgs; })
              // (import ./plugin-config/neotest)
              // (import ./plugin-config/noice { inherit pkgs; })
              // (import ./plugin-config/obsidian)
              // (import ./plugin-config/octo)
              // (import ./plugin-config/oil)
              // (import ./plugin-config/oil-git-status)
              // (import ./plugin-config/origami)
              // (import ./plugin-config/otter)
              // (import ./plugin-config/parinfer-rust)
              // (import ./plugin-config/remote-nvim { inherit pkgs; })
              // (import ./plugin-config/render-markdown)
              // (import ./plugin-config/rustaceanvim { inherit pkgs; })
              // (import ./plugin-config/schemastore)
              // (import ./plugin-config/smartcolumn)
              // (import ./plugin-config/snacks)
              // (import ./plugin-config/tailwind-tools)
              // (import ./plugin-config/tiny-devicons-auto-colors)
              // (import ./plugin-config/tiny-inline-diagnostic)
              // (import ./plugin-config/treesitter { inherit pkgs; })
              // (import ./plugin-config/treesitter-context)
              // (import ./plugin-config/trouble)
              // (import ./plugin-config/which-key)
              // (import ./plugin-config/zk)
          );
        } // (
          # (import ./colorschemes/ayu)
          # (import ./colorschemes/catppuccin)
          # (import ./colorschemes/everforest)
          # (import ./colorschemes/gruvbox)
          # (import ./colorschemes/kanagawa-paper)
          # (import ./colorschemes/melange)
          # (import ./colorschemes/modus)
          # (import ./colorschemes/monokai-pro)
          # (import ./colorschemes/nightfox)
          # (import ./colorschemes/rose-pine)
          # (import ./colorschemes/tokyonight)
          # (import ./colorschemes/vscode)
          # (import ./colorschemes/poimandres)
          # (import ./colorschemes/onedark)
          (import ./colorschemes/bamboo)
        );
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

            config = {
              allowUnfree = true;
            };

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
                vimPlugins = prev.vimPlugins // {
                  avante-nvim = prev.vimPlugins.avante-nvim.overrideAttrs (oldAttrs: {
                    src = pkgs.fetchFromGitHub {
                      owner = "yetone";
                      repo = "avante.nvim";
                      rev = "40af7113a295b8c4f8040450076bc72f85e2c1ed";
                      hash = "sha256-G+zONb3ffqXDH9yVZzo1W957l8N7V0x/D82xL54gO38=";
                    };
                  });
                };
              })
            ];
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
              '';
            };
          };
        };
    };
}
