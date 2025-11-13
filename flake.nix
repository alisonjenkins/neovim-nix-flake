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
          ];

          extraConfigLua = ''
            -- Performance optimizations
            vim.g.loaded_node_provider = 0  -- Disable Node.js provider
            vim.g.loaded_perl_provider = 0  -- Disable Perl provider
            vim.g.loaded_ruby_provider = 0  -- Disable Ruby provider
            vim.opt.redrawtime = 1500        -- Faster redraw timeout

            -- LSP performance optimizations
            vim.lsp.set_log_level("ERROR")    -- Reduce LSP logging for performance

            -- Defer LSP attachment to reduce startup I/O (helps with AV scanning)
            -- This spreads file access over time instead of all at once
            local lsp_defer_time = 150  -- milliseconds

            -- Track which buffers have had LSP deferred
            local lsp_deferred_buffers = {}

            -- Store the original buf_attach_client function
            local original_buf_attach_client = vim.lsp.buf_attach_client

            -- Override buf_attach_client to defer LSP attachment
            vim.lsp.buf_attach_client = function(client, bufnr)
              local buf = bufnr or vim.api.nvim_get_current_buf()

              -- Skip if already deferred for this buffer
              if lsp_deferred_buffers[buf] then
                return original_buf_attach_client(client, buf)
              end

              -- Mark as deferred and schedule attachment
              lsp_deferred_buffers[buf] = true
              vim.defer_fn(function()
                -- Check if buffer is still valid
                if vim.api.nvim_buf_is_valid(buf) then
                  original_buf_attach_client(client, buf)
                end
              end, lsp_defer_time)
            end

            -- Clean up tracking when buffers are deleted
            vim.api.nvim_create_autocmd("BufDelete", {
              callback = function(args)
                lsp_deferred_buffers[args.buf] = nil
              end,
            })

            -- Directory setup (sync - needed immediately)
            vim.o.backupdir = vim.fn.stdpath("data") .. "/backup"
            vim.o.directory = vim.fn.stdpath("data") .. "/directory"
            vim.o.sessionoptions = vim.o.sessionoptions .. ",globals"
            vim.o.undodir = vim.fn.stdpath("data") .. "/undo"
            vim.loop.fs_mkdir(vim.o.backupdir, 750)
            vim.loop.fs_mkdir(vim.o.directory, 750)
            vim.loop.fs_mkdir(vim.o.undodir, 750)

            -- Defer non-critical plugin setups to speed up startup
            vim.defer_fn(function()
              require('jj').setup({})
              require('pipeline').setup({})
            end, 50)

            -- Defer UpdateRemotePlugins to avoid blocking startup
            vim.defer_fn(function()
              if vim.fn.argc() == 0 then
                vim.cmd("silent! UpdateRemotePlugins")
              end
            end, 100)

            -- Additional startup optimizations for AV scanning environments
            -- Disable some filesystem watchers that trigger excessive AV scans
            vim.opt.shadafile = "NONE"  -- Disable shada during startup
            vim.defer_fn(function()
              vim.opt.shadafile = ""    -- Re-enable after startup complete
              vim.cmd("silent! rshada") -- Restore session data
            end, 200)

            -- Reduce filesystem polling for better performance with AV
            vim.opt.swapfile = true  -- Keep swapfiles but reduce write frequency
            vim.opt.updatecount = 200  -- Write swap after 200 characters (default: 200)

            -- Batch directory scans to reduce AV overhead
            vim.opt.wildignore:append({
              "*.o", "*.obj", "*.dylib", "*.bin", "*.dll", "*.exe",
              "*/.git/*", "*/.svn/*", "*/.DS_Store", "*/node_modules/*",
              "*/venv/*", "*/__pycache__/*", "*.pyc",
              "*/.nix-profile/*", "*/.nix-defexpr/*",
              -- macOS-specific AV exclusions for search performance
              "*.app/*",                       -- macOS application bundles
              "*/.Spotlight-V100/*",           -- Spotlight metadata
              "*/.fseventsd/*",                -- FSEvents
              "*/.DocumentRevisions-V100/*",   -- Document versions
              "*/.TemporaryItems/*",           -- Temporary items
              "*/.Trashes/*",                  -- Trash directories
              "*/Library/Caches/*",            -- Cache directories
              "*/DerivedData/*",               -- Xcode derived data
              "*/.build/*",                    -- Swift/Xcode build artifacts
            })

            -- Custom async git commands that only show output on error
            -- This replaces Git! push, fetch, etc. with silent versions
            local function async_git_command(args, desc)
              local output = {}
              local stderr = {}

              vim.fn.jobstart(vim.list_extend({"git"}, args), {
                cwd = vim.fn.FugitiveGitDir() and vim.fn.FugitiveWorkTree() or vim.fn.getcwd(),
                stdout_buffered = true,
                stderr_buffered = true,
                on_stdout = function(_, data)
                  if data then
                    vim.list_extend(output, data)
                  end
                end,
                on_stderr = function(_, data)
                  if data then
                    vim.list_extend(stderr, data)
                  end
                end,
                on_exit = function(_, exit_code)
                  if exit_code == 0 then
                    vim.notify(desc .. " completed successfully", vim.log.levels.INFO)
                  else
                    -- Show error in a split
                    local all_output = vim.list_extend(vim.list_extend({}, output), stderr)
                    -- Filter out empty lines
                    all_output = vim.tbl_filter(function(line) return line ~= "" end, all_output)

                    if #all_output > 0 then
                      local buf = vim.api.nvim_create_buf(false, true)
                      vim.api.nvim_buf_set_lines(buf, 0, -1, false, all_output)
                      vim.bo[buf].filetype = "git"

                      vim.cmd("botright split")
                      vim.api.nvim_win_set_buf(0, buf)
                      vim.cmd("wincmd p")
                    end

                    vim.notify(desc .. " failed (exit code: " .. exit_code .. ")", vim.log.levels.ERROR)
                  end
                end,
              })
            end

            -- Create custom commands
            vim.api.nvim_create_user_command("GitPushSilent", function()
              async_git_command({"push"}, "Git push")
            end, {})

            vim.api.nvim_create_user_command("GitPushForceLeaseSilent", function()
              async_git_command({"push", "--force-with-lease"}, "Git push --force-with-lease")
            end, {})

            vim.api.nvim_create_user_command("GitPushTagsSilent", function()
              async_git_command({"push", "--tags"}, "Git push --tags")
            end, {})

            vim.api.nvim_create_user_command("GitFetchSilent", function(opts)
              local args = {"fetch"}
              if opts.args ~= "" then
                vim.list_extend(args, vim.split(opts.args, "%s+"))
              else
                vim.list_extend(args, {"origin", "--prune"})
              end
              async_git_command(args, "Git fetch")
            end, { nargs = "*" })
          '';

          extraFiles = {
            "ftplugin/http.lua".text = import ./ftplugin/http.lua.nix;
          };

          extraPackages = with pkgs; [
            # alejandra
            # lldb
            (python3.withPackages (python-pkgs: [ python-pkgs.pylatexenc ]))
            black
            cowsay
            fd
            fortune
            ghostscript
            gofumpt
            golangci-lint
            golines
            grpcurl
            imagemagick
            isort
            jq
            jujutsu
            jupyter
            lsof
            mermaid-cli
            nixpkgs-fmt
            nodePackages.prettier
            openssl
            postgresql
            prettierd
            ripgrep
            rust-analyzer
            rustfmt
            shfmt
            sqlite
            stable.tectonic
            stylua
            terraform
            websocat
            wordnet
          ];

          extraPlugins = with pkgs.vimPlugins; [
            blink-cmp-avante
            blink-cmp-conventional-commits
            vim-dadbod
            vim-dadbod-completion
            vim-dadbod-ui
            vim-pencil
            vim-table-mode

            (pkgs.vimUtils.buildVimPlugin {
              name = "blink-cmp-tmux";
              src = pkgs.fetchFromGitHub {
                owner = "mgalliou";
                repo = "blink-cmp-tmux";
                rev = "4586c705b6f80b536c34a61ed0d3cd4d7f08322d";
                hash = "sha256-99wmBgU7Yt6eIAXppJUOYQVuiFcX8q8pmk6rKv/d87Q=";
              };
            })

            (pkgs.vimUtils.buildVimPlugin {
              name = "jj-nvim";
              src = pkgs.fetchFromGitHub {
                owner = "NicolasGB";
                repo = "jj.nvim";
                rev = "d8280091989d10fd95f1109194846b613d5c4bd0";
                hash = "sha256-7taOkKswx5LdAi3Gx8jKHNskR/bshhc8wc1KrC1DK8Y=";
              };
            })

            (pkgs.vimUtils.buildVimPlugin {
              name = "pipeline-nvim";
              src = pkgs.fetchFromGitHub {
                owner = "topaxi";
                repo = "pipeline.nvim";
                rev = "d14a27ba7f25ecb72e28bb9844672de99b151eaa";
                hash = "sha256-Pl1HkXpnyAIVct3BjGtGTQf2M270Gq5wSh+KUKnL1Tk=";
              };
            })
          ];

          extraPython3Packages = p: [
            p.ipykernel
            p.jupyter-client
            p.numpy
            # p.plotly
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
            updatetime = 300;    # Restored to 300ms for better AV performance (was 50ms)
            wrap = false;
            writebackup = true;
            # Performance optimizations
            synmaxcol = 300;     # Limit syntax highlighting columns
            lazyredraw = false;   # Don't redraw during macros (keep false for smooth UI)
            regexpengine = 0;    # Auto-select regex engine
            maxmempattern = 1000; # Limit memory for pattern matching
            # Search optimizations for AV-heavy environments (macOS Defender)
            hlsearch = false;    # Disable search highlighting by default (use Telescope/Snacks instead)
            incsearch = true;    # Keep incremental search enabled
            # Timeout settings
            timeout = true;
            ttimeout = true;
            ttimeoutlen = 50;
          };

          keymaps = [ ]
            ++ import ./keymaps/ai/avante
            ++ import ./keymaps/ai/codecompanion
            ++ import ./keymaps/ai/sidekick
            ++ import ./keymaps/buffers
            ++ import ./keymaps/db
            ++ import ./keymaps/debugging
            ++ import ./keymaps/folding
            ++ import ./keymaps/git
            ++ import ./keymaps/git/fugitive
            ++ import ./keymaps/harpoon
            ++ import ./keymaps/jujutsu
            ++ import ./keymaps/jumps
            ++ import ./keymaps/lsp
            ++ import ./keymaps/notifications
            ++ import ./keymaps/obsidian
            ++ import ./keymaps/rust-lsp
            ++ import ./keymaps/search
            ++ import ./keymaps/tabs
            ++ import ./keymaps/terminal
            ++ import ./keymaps/testing
            ++ import ./keymaps/toggles
            ++ import ./keymaps/zk;

          performance = {
            byteCompileLua = {
              enable = true;
              nvimRuntime = true;
              plugins = true;
            };

            combinePlugins = {
              enable = true;

              standalonePlugins = with pkgs.vimPlugins; [
                conform-nvim
                copilot-lua
                friendly-snippets
                image-nvim
                mini-nvim
                nvim-jdtls
                nvim-treesitter
                nvim-treesitter-parsers.http
                oil-nvim
                snacks-nvim
              ];
            };
          };

          plugins = {
            bacon.enable = true;
            cmp-cmdline.enable = true;
            cmp-dap.enable = true;
            cmp-nvim-lsp.enable = true;
            comfy-line-numbers.enable = true;
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
            rhubarb.enable = true;
            roslyn.enable = false;
            sleuth.enable = true;
            smear-cursor.enable = true;
            specs.enable = false;
            tmux-navigator.enable = true;
            treesitter-refactor.enable = true;
            treesitter-textobjects.enable = true;
            ts-autotag.enable = true;
            ts-context-commentstring.enable = true;
            typst-vim.enable = true;
            vim-css-color.enable = true;
            web-devicons.enable = true;
            wilder.enable = true;
            wrapping.enable = true;
            zig.enable = true;
          }
          // (
            # (import ./plugin-config/alpha)
              # // (import ./plugin-config/teamtype)
              # // (import ./plugin-config/tailwind-tools)
              (import ./plugin-config/auto-session)
              // (import ./plugin-config/arrow)
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
              // (import ./plugin-config/cybu)
              // (import ./plugin-config/dap { inherit pkgs; })
              // (import ./plugin-config/dap-go { inherit pkgs; })
              // (import ./plugin-config/dap-lldb { inherit pkgs; })
              // (import ./plugin-config/dap-python)
              // (import ./plugin-config/dap-ui)
              // (import ./plugin-config/dap-virtual-text)
              // (import ./plugin-config/faster-nvim)
              // (import ./plugin-config/git-conflict)
              // (import ./plugin-config/harpoon)
              // (import ./plugin-config/image)
              // (import ./plugin-config/img-clip { inherit  pkgs; })
              // (import ./plugin-config/indent-tools)
              // (import ./plugin-config/kulala { inherit pkgs; })
              // (import ./plugin-config/lazydev)
              // (import ./plugin-config/lsp { inherit  pkgs; })
              // (import ./plugin-config/lspkind)
              // (import ./plugin-config/lualine)
              // (import ./plugin-config/luasnip)
              // (import ./plugin-config/lz-n)
              // (import ./plugin-config/mini)
              // (import ./plugin-config/modicator)
              // (import ./plugin-config/navbuddy)
              // (import ./plugin-config/neorg { inherit pkgs; })
              // (import ./plugin-config/neotest { inherit pkgs; })
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
              // (import ./plugin-config/sidekick)
              // (import ./plugin-config/smartcolumn)
              // (import ./plugin-config/snacks)
              // (import ./plugin-config/tardis)
              // (import ./plugin-config/tiny-devicons-auto-colors)
              // (import ./plugin-config/tiny-inline-diagnostic)
              // (import ./plugin-config/treesitter { inherit pkgs; })
              // (import ./plugin-config/treesitter-context)
              // (import ./plugin-config/trouble)
              // (import ./plugin-config/twilight)
              // (import ./plugin-config/vim-be-good)
              // (import ./plugin-config/which-key)
              // (import ./plugin-config/zen-mode)
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
                      rev = "4390828e88c8526649d1af7000df5c512fa49bbb";
                      hash = "sha256-asNRx4dhtzWVK6M2vWqATQtcHzrVQKvGQaqyVGSlunw=";
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
