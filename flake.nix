{
  description = "Alison Jenkins's Neovim Flake";

  inputs = {
    flake-parts.url = "github:hercules-ci/flake-parts";
    nixpkgs-master.url = "github:nixos/nixpkgs";
    nixpkgs-stable.url = "github:nixos/nixpkgs/nixos-24.05";
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    nixvim.url = "github:nix-community/nixvim";
    treefmt-nix.url = "github:numtide/treefmt-nix";
  };

  outputs = {
    flake-parts,
    nixvim,
    treefmt-nix,
    ...
  } @ inputs: let
    config = {pkgs, ...}:
    # let
    # treesitter-powershell-grammar = pkgs.tree-sitter.buildGrammar {
    #   language = "powershell";
    #   version = "2024-07-31";
    #   src = pkgs.fetchFromGitHub {
    #     owner = "airbus-cert";
    #     repo = "tree-sitter-powershell";
    #     rev = "fc15514b2f1dbba9c58528d15a3708f89eda6a01";
    #     hash = "sha256-StVnRNM0HPevLSRDIDr+Sakjo+NqXYWPPUFjI29Cowo=";
    #   };
    #   meta.homepage = "https://github.com/airbus-cert/tree-sitter-powershell/";
    # };
    # treesitter-vhdl-grammar = pkgs.tree-sitter.buildGrammar {
    #   language = "vhdl";
    #   version = "2024-07-18";
    #   src = pkgs.fetchFromGitHub {
    #     owner = "jpt13653903";
    #     repo = "tree-sitter-vhdl";
    #     rev = "4ab3e251eae8890a020d083d00acd1b8c2653c07";
    #     hash = "sha256-egNgZ1GgRNvIdH08cf6V83bMeOECs23yiV5RzcXZENg=";
    #   };
    #   meta.homepage = "https://github.com/jpt13653903/tree-sitter-vhdl";
    # };
    #
    # treesitter-vrl-grammar = pkgs.tree-sitter.buildGrammar {
    #   language = "vrl";
    #   version = "2024-07-18";
    #   src = pkgs.fetchFromGitHub {
    #     owner = "belltoy";
    #     repo = "tree-sitter-vrl";
    #     rev = "274b3ce63f72aa8ffea18e7fc280d3062d28f0ba";
    #     hash = "sha256-R+wuG8UkvGA11uTiiUAdzzgjRv1ik4W+qh3YwIREUd4=";
    #   };
    #   meta.homepage = "https://github.com/belltoy/tree-sitter-vrl";
    # };
    # in
    {
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
        {
          event = ["BufEnter"];
          pattern = ["github.com_*.txt"];
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

        do
          local parser_config = require("nvim-treesitter.parsers").get_parser_configs()

          -- parser_config.powershell = {
          --   install_info = {
          --     url = "$${treesitter-powershell-grammar}",
          --     files = {"src/parser.c"},
          --     filetype = "powershell",
          --   }
          --}

          -- parser_config.vhdl = {
            -- install_info = {
              -- url = "$${treesitter-vhdl-grammar}",
              -- files = {"src/parser.c"},
              -- filetype = "vhdl",
            -- }
          -- }

          -- parser_config.vrl = {
            -- install_info = {
              -- url = "$${treesitter-vrl-grammar}",
              -- files = {"src/parser.c"},
              -- filetype = "vrl",
            -- }
          -- }
        end

        require('outline').setup({})
        require('render-markdown').setup({})
      '';

      extraFiles = {
        "ftplugin/java.lua".text = ''
          local config = {
            cmd = {'${pkgs.jdt-language-server}/bin/jdtls', '--jvm-arg=-javaagent:${pkgs.lombok}/share/java/lombok.jar', '--jvm-arg=-Xbootclasspath/a:${pkgs.lombok}/share/java/lombok.jar'},
            root_dir = vim.fs.dirname(vim.fs.find({'gradlew', '.git', 'mvnw'}, { upward = true })[1]),
          }
          require('jdtls').start_or_attach(config)
        '';
      };

      extraPackages = with pkgs; [
        alejandra
        black
        gofumpt
        golines
        isort
        jq
        lldb
        nodePackages.prettier
        prettierd
        rustfmt
        shfmt
        stylua
      ];

      extraPlugins = with pkgs.vimPlugins; [
        nvim-jdtls
        outline-nvim
        pkgs.master.vimPlugins.render-markdown-nvim
        vim-table-mode
        # treesitter-powershell-grammar
        # treesitter-vhdl-grammar
        # treesitter-vrl-grammar
      ];

      extraPython3Packages = p: [
        # p.kaleido
        p.numpy
        p.plotly
        p.pnglatex
        p.pyperclip
      ];

      opts = {
        # foldexpr = "v:lua.vim.treesitter.foldexpr()";
        # foldmethod = "expr";
        # foldmethod = "manual";
        # foldtext = "v:lua.vim.treesitter.foldtext()";
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
        ++ import ./keymaps/leap
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
        bacon.enable = true;
        bufdelete.enable = true;
        ccc.enable = true;
        cmp-dap.enable = true;
        cmp-nvim-lsp.enable = true;
        comment.enable = true;
        committia.enable = true;
        direnv.enable = true;
        fidget.enable = true;
        friendly-snippets.enable = true;
        fugitive.enable = true;
        gitignore.enable = true;
        gitsigns.enable = true;
        headlines.enable = true;
        helm.enable = true;
        helpview.enable = true;
        hmts.enable = true;
        image.enable = true;
        indent-blankline.enable = true;
        lastplace.enable = true;
        lspkind.enable = true;
        lspsaga.enable = true;
        lualine.enable = true;
        markdown-preview.enable = true;
        molten.enable = true;
        navic.enable = true;
        nix.enable = true;
        noice.enable = true;
        numbertoggle.enable = true;
        nvim-ufo.enable = true;
        rainbow-delimiters.enable = true;
        schemastore.enable = true;
        sleuth.enable = true;
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

        alpha = {
          enable = true;
          theme = "startify";
        };

        arrow = {
          enable = false;

          settings = {
            mappings = {
              edit = "e";
              delete_mode = "d";
              clear_all_items = "C";
              toggle = "s";
              open_vertical = "v";
              open_horizontal = "-";
              quit = "q";
              remove = "x";
              next_item = "]";
              prev_item = "[";
            };
            separate_save_and_remove = false;
            leader_key = null;
            save_key = "cwd";
            global_bookmarks = false;
            index_keys = "123456789zxcbnmZXVBNM,afghjklAFGHJKLwrtyuiopWRTYUIOP";
            full_path_list = ["update_stuff"];
          };
        };

        clipboard-image = {
          enable = true;
          clipboardPackage = (
            if pkgs.stdenv.isLinux
            then pkgs.xclip
            else
              (
                if pkgs.stdenv.isDarwin
                then pkgs.pngpaste
                else []
              )
          );
        };

        conform-nvim = {
          enable = true;

          settings = {
            formatters_by_ft = {
              "_" = ["trim_whitespace"];
              go = ["goimports" "golines" "gofmt" "gofumpt"];
              javascript = [["prettierd" "prettier"]];
              json = ["jq"];
              lua = ["stylua"];
              nix = ["alejandra"];
              python = ["isort" "black"];
              rust = ["rustfmt"];
              sh = ["shfmt"];
              terraform = ["terraform_fmt"];
            };

            format_on_save = ''
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
                return { timeout_ms = 1000, lsp_fallback = true }
              end
            '';
          };
        };

        cmp = {
          enable = true;
          autoEnableSources = true;

          settings = {
            mapping = {
              "<C-d>" = "cmp.mapping.scroll_docs(-4)";
              "<C-e>" = "cmp.mapping.abort()";
              "<C-f>" = "cmp.mapping.scroll_docs(4)";
              "<C-n>" = "cmp.mapping.select_next_item { behavior = cmp.SelectBehavior.Insert }";
              "<C-u>" = "cmp.mapping.complete({})";
              "<C-p>" = "cmp.mapping.select_prev_item { behavior = cmp.SelectBehavior.Insert }";
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
              "<tab>" = "cmp.config.disable";
            };

            snippet = {
              expand = ''
                function(args)
                require("luasnip").lsp_expand(args.body)
                end
              '';
            };

            sources = [
              {name = "nvim_lsp";}
              {
                name = "luasnip";
                option = {show_autosnippets = true;};
              }
              {name = "path";}
              {name = "buffer";}
            ];
          };
        };

        crates-nvim = {
          enable = true;

          extraOptions = {
            lsp = {
              actions = true;
              completion = true;
              enabled = true;
              hover = true;
            };
          };
        };

        dap = {
          enable = true;

          extensions = {
            dap-go.enable = true;
            dap-python.enable = true;
            dap-ui.enable = true;
            dap-virtual-text.enable = true;
          };
        };

        firenvim = {
          enable = true;

          settings = {
            globalSettings.alt = "all";

            localSettings = {
              ".*" = {
                cmdline = "firenvim";
                content = "text";
                priority = 0;
                selector = "textarea";
                takeover = "never";
              };
            };
          };
        };

        gitlinker = {
          enable = true;
          mappings = null;
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

        leap = {
          enable = true;
          addDefaultMappings = false;
        };

        luasnip = {
          enable = true;
          fromVscode = [{}];
        };

        lsp = {
          enable = true;
          inlayHints = true;

          servers = {
            ansiblels.enable = true;
            bashls.enable = true;
            ccls.enable = true;
            cssls.enable = true;
            dockerls.enable = true;
            emmet-ls.enable = true;
            gopls.enable = true;
            html.enable = true;
            java-language-server.enable = false;
            jdt-language-server.enable = false;
            jsonls.enable = true;
            lua-ls.enable = true;
            nil-ls.enable = true;
            nushell.enable = true;
            pylsp.enable = true;
            pylyzer.enable = false;
            ruff-lsp.enable = false;
            tailwindcss.enable = true;
            terraformls.enable = true;
            ts-ls.enable = true;
            zls.enable = false;

            helm-ls = {
              enable = true;
              filetypes = ["helm"];
            };

            yamlls = {
              enable = true;
              filetypes = ["yaml"];
            };
          };
        };

        mini = {
          enable = true;

          modules = {
            ai = {
              n_lines = 50;
              search_method = "cover_or_next";
            };

            bufremove = {};

            hipatterns = {
              highlighters = {
                # *FIXME*
                fixme = {
                  pattern = "%f[%w]()FIXME()%f[%W]";
                  group = "MiniHipatternsFixme";
                };
                # *HACK*
                hack = {
                  pattern = "%f[%w]()HACK()%f[%W]";
                  group = "MiniHipatternsHack";
                };
                # *TODO*
                todo = {
                  pattern = "%f[%w]()TODO()%f[%W]";
                  group = "MiniHipatternsTodo";
                };
                # *NOTE*
                note = {
                  pattern = "%f[%w]()NOTE()%f[%W]";
                  group = "MiniHipatternsNote";
                };

                # Highlight hex color strings (`#rrggbb`) using that color
                hex_color = "hipatterns.gen_highlighter.hex_color()";
              };
            };

            surround = {
              mappings = {
                add = "gsa";
                delete = "gsd";
                find = "gsf";
                find_left = "gsF";
                highlight = "gsh";
                replace = "gsr";
                update_n_lines = "gsn";
              };
            };
          };
        };

        navbuddy = {
          enable = true;
          lsp.autoAttach = true;
        };

        neotest = {
          enable = true;

          adapters = {
            bash.enable = true;
            go.enable = true;
            java.enable = true;
            plenary.enable = true;
            python.enable = true;
            rust.enable = true;
            zig.enable = true;
          };

          settings = {
            log_level = "warn";

            discovery = {
              enabled = true;
            };

            output_panel = {
              enabled = true;
            };
          };
        };

        notify = {
          enable = true;
          timeout = 1000;
          topDown = false;
        };

        octo = {
          enable = true;

          settings = {
            suppress_missing_scope = {
              projects_v2 = true;
            };
          };
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
          enable = true;
          enableTelescope = true;

          settings = {
            manual_mode = true;

            patterns = [
              ".bzr"
              ".git"
              ".hg"
              ".svn"
              "Cargo.toml"
              "Makefile"
              "_darcs"
              "flake.nix"
              "flake.nix"
              "go.mod"
              "package.json"
              "pom.xml"
            ];
          };
        };

        rustaceanvim = {
          enable = true;

          settings = {
            server = {
              default_settings = {
                rust-analyzer = {
                  files = {
                    excludeDirs = [".direnv"];
                  };
                };
              };
            };
          };
        };

        smartcolumn = {
          enable = true;

          settings = {
            colorcolumn = "80";
            scope = "file";

            disable_filetypes = [
              "NvimTree"
              "Trouble"
              "checkhealth"
              "help"
              "lazy"
              "lspinfo"
              "noice"
            ];
          };
        };

        telescope = {
          enable = true;
          extensions = {
            fzy-native.enable = true;

            frecency = {
              enable = true;

              settings = {
                db_safe_mode = false;
              };
            };
          };
        };

        treesitter = {
          enable = true;

          grammarPackages =
            pkgs.vimPlugins.nvim-treesitter.passthru.allGrammars
            ++ [
              # treesitter-powershell-grammar
              # treesitter-vhdl-grammar
              # treesitter-vrl-grammar
            ];

          settings = {
            textobjects.enable = true;

            highlight = {
              enable = true;

              disable = ''
                function(lang, bufnr)
                  return vim.api.nvim_buf_line_count(bufnr) > 10000
                end
              '';
            };

            incremental_selection = {
              enable = false;
            };

            indent = {
              enable = false;
            };
          };
        };

        treesitter-context = {
          enable = true;
          settings = {
            max_lines = 4;
          };
        };

        which-key = {
          enable = true;
          settings = {
            spec = [
              {
                __unkeyed-1 = "<leader>b";
                desc = "Buffers";
              }
              {
                __unkeyed-1 = "<leader>d";
                desc = "Debugging";
              }
              {
                __unkeyed-1 = "<leader>dB";
                desc = "Breakpoint";
              }
              {
                __unkeyed-1 = "<leader>ds";
                desc = "Step";
              }
              {
                __unkeyed-1 = "<leader>g";
                desc = "Git";
              }
              {
                __unkeyed-1 = "<leader>gp";
                desc = "Git Push";
              }
              {
                __unkeyed-1 = "<leader>gP";
                desc = "Github PR";
              }
              {
                __unkeyed-1 = "<leader>h";
                desc = "Harpoon";
              }
              {
                __unkeyed-1 = "<leader>l";
                desc = "LSP";
              }
              {
                __unkeyed-1 = "<leader>lb";
                desc = "Bacon";
              }
              {
                __unkeyed-1 = "<leader>lf";
                desc = "LSP Finder";
              }
              {
                __unkeyed-1 = "<leader>lp";
                desc = "LSP Peek";
              }
              {
                __unkeyed-1 = "<leader>lr";
                desc = "Rust LSP";
              }
              {
                __unkeyed-1 = "<leader>lrm";
                desc = "Rust LSP Move Item";
              }
              {
                __unkeyed-1 = "<leader>s";
                desc = "Search using Telescope";
              }
              {
                __unkeyed-1 = "<leader>t";
                desc = "Testing";
              }
              {
                __unkeyed-1 = "<leader>z";
                desc = "Zettelkasten";
              }
            ];
          };
        };

        zk = {
          enable = true;
          settings = {
            picker = "telescope";
          };
        };
      };
    };
  in
    flake-parts.lib.mkFlake {inherit inputs;} {
      systems = [
        "aarch64-darwin"
        "aarch64-linux"
        "x86_64-darwin"
        "x86_64-linux"
      ];

      imports = [inputs.treefmt-nix.flakeModule];

      perSystem = {
        pkgs,
        system,
        ...
      }: let
        nixvimLib = nixvim.lib.${system};
        nixvim' = nixvim.legacyPackages.${system};
        nvim = nixvim'.makeNixvimWithModule {
          inherit pkgs;
          module = config;
          # You can use `extraSpecialArgs` to pass additional arguments to your module files
          extraSpecialArgs = {
            # inherit (inputs) foo;
          };
        };
      in {
        _module.args.pkgs = import inputs.nixpkgs {
          inherit system;
          overlays = [
            (
              final: _prev: {
                master = import inputs.nixpkgs-master {
                  system = final.system;
                  config.allowUnfree = true;
                };
              }
            )
            (
              final: _prev: {
                stable = import inputs.nixpkgs-stable {
                  system = final.system;
                  config.allowUnfree = true;
                };
              }
            )
          ];
          config = {};
        };
        checks = {
          # Run `nix flake check .` to verify that your config is not broken
          default = nixvimLib.check.mkTestDerivationFromNvim {
            inherit nvim;
            name = "A nixvim configuration";
          };
        };

        packages = {
          # Lets you run `nix run .` to start nixvim
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
