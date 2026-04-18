{ pkgs, ... }: {
  blink-cmp = {
    enable = true;

    settings = {
      appearance = {
        # Blink does not expose its default kind icons so you must copy them all (or set your custom ones) and add Copilot
        kind_icons = {
          Class = "󱡠";
          Color = "󰏘";
          Constant = "󰏿";
          Constructor = "󰒓";
          # Copilot = "";
          Enum = "󰦨";
          EnumMember = "󰦨";
          Event = "󱐋";
          Field = "󰜢";
          File = "󰈔";
          Folder = "󰉋";
          Function = "󰊕";
          Interface = "󱡠";
          Keyword = "󰻾";
          Method = "󰊕";
          Module = "󰅩";
          Operator = "󰪚";
          Property = "󰖷";
          Reference = "󰬲";
          Snippet = "󱄽";
          Struct = "󱡠";
          Text = "󰉿";
          TypeParameter = "󰬛";
          Unit = "󰪚";
          Value = "󰦨";
          Variable = "󰆦";
        };
      };

      completion = {
        accept = {
          auto_brackets = {
            enabled = false;
          };
        };

        documentation = {
          auto_show = true;
          auto_show_delay_ms = 200;

          window = {
            border = "rounded";
          };
        };

        ghost_text = {
          enabled = true;
        };

        list = {
          selection = {
            auto_insert = false; # Disabled - let user explicitly select completions
            preselect = true; # Still highlight first item
          };
        };

        menu = {
          draw.__raw = ''
            {
              -- We don't need label_description now because label and label_description are already
              -- combined together in label by colorful-menu.nvim.
              columns = { { "kind_icon" }, { "label", gap = 1 } },
              components = {
                label = {
                  text = function(ctx)
                    return require("colorful-menu").blink_components_text(ctx)
                  end,
                  highlight = function(ctx)
                    return require("colorful-menu").blink_components_highlight(ctx)
                  end,
                },
              },
            }
          '';
        };

        trigger = {
          show_on_accept_on_trigger_character = true;
          show_on_keyword = true;
          show_on_trigger_character = true;
        };
      };

      fuzzy = {
        implementation = "rust";

        prebuilt_binaries = {
          download = false;
          force_version = "v${pkgs.vimPlugins.blink-cmp.version}";
        };
      };

      snippets = {
        preset = "luasnip";
      };

      sources = {
        default = [
          "lsp"
          "path"
          "snippets"
          "lazydev"
          "dap"
          "buffer"
        ];

        per_filetype = {
          gitcommit = [ "conventional_commits" "git" "emoji" "spell" "buffer" ];
          NeogitCommitMessage = [ "conventional_commits" "git" "emoji" "spell" "buffer" ];
          markdown = [ "lsp" "path" "snippets" "emoji" "spell" "buffer" ];
          sh = [ "lsp" "path" "snippets" "env" "buffer" ];
          bash = [ "lsp" "path" "snippets" "env" "buffer" ];
          nix = [ "lsp" "path" "snippets" "env" "buffer" ];
          # Terraform: rely on tfls LSP snippets only — skip the snippets source.
          terraform = [ "lsp" "path" "lazydev" "dap" "buffer" ];
        };

        providers = {
          buffer = {
            name = "Buffer";
            module = "blink.cmp.sources.buffer";
            score_offset = -3; # Lower priority - only as fallback
            min_keyword_length = 3; # Don't trigger too early
          };

          conventional_commits = {
            name = "Conventional Commits";
            module = "blink-cmp-conventional-commits";

            enabled.__raw = ''
              function()
                return vim.bo.filetype == "gitcommit"
              end
            '';
          };

          dap = {
            name = "DAP";
            module = "blink-cmp-dap";
            score_offset = 5;
          };

          emoji = {
            module = "blink-emoji";
            name = "Emoji";
            score_offset = -1;

            enabled.__raw = ''
              function()
                local ft = vim.bo.filetype
                return ft == "gitcommit" or ft == "markdown" or ft == "NeogitCommitMessage"
              end
            '';
          };

          env = {
            module = "blink-cmp-env";
            name = "Env";
            score_offset = -2;

            enabled.__raw = ''
              function()
                local ft = vim.bo.filetype
                return ft == "sh" or ft == "bash" or ft == "zsh" or ft == "nix"
              end
            '';
          };

          spell = {
            module = "blink-cmp-spell";
            name = "Spell";
            score_offset = -5;

            enabled.__raw = ''
              function()
                local ft = vim.bo.filetype
                return ft == "markdown" or ft == "text" or ft == "gitcommit" or ft == "NeogitCommitMessage"
              end
            '';
          };

          dictionary = {
            module = "blink-cmp-dictionary";
            name = "Dict";
            min_keyword_length = 4; # Increased to reduce noise
            score_offset = -5; # Very low priority
            opts = { };
          };

          git = {
            module = "blink-cmp-git";
            name = "git";
            score_offset = 5; # Much lower - only slightly above LSP

            # Only enable in git-related contexts
            enabled.__raw = ''
              function()
                local ft = vim.bo.filetype
                return ft == "gitcommit" or ft == "NeogitCommitMessage" or ft == "octo"
              end
            '';

            opts = {
              commit = { };
              git_centers = { git_hub = { }; };
            };
          };

          lazydev = {
            name = "LazyDev";
            module = "lazydev.integrations.blink";
            score_offset = 10; # High priority for Neovim Lua development
          };

          lsp = {
            name = "LSP";
            module = "blink.cmp.sources.lsp";
            async = true; # Changed to async for better performance
            enabled = true;
            max_items = null;
            min_keyword_length = 0;
            override = null;
            score_offset = 4; # Moderate priority - LSP is usually most relevant
            should_show_items = true;
            timeout_ms = 2000;

            fallbacks = [
              "buffer"
            ];
          };

          path = {
            name = "Path";
            module = "blink.cmp.sources.path";
            score_offset = 3; # Good priority for path completions

            fallbacks = [
              "buffer"
            ];

            opts = {
              label_trailing_slash = true;
              show_hidden_files_by_default = false;
              trailing_slash = false;
            };
          };

          ripgrep = {
            async = true;
            module = "blink-ripgrep";
            name = "Ripgrep";
            score_offset = -2; # Lower priority - useful but not primary
            opts = {
              prefix_min_len = 4; # Increased to reduce noise
              project_root_marker = ".git";
              additional_rg_options = { };
              fallback_to_regex_highlighting = true;
              ignore_paths = { };
              additional_paths = { };
              debug = false;

              backend = {
                use = "ripgrep";

                ripgrep = {
                  context-size = 5;
                  max_filesize = "1M";
                  project_root_fallback = true;
                  search_casing = "--ignore-case";
                };
              };
            };
          };

          tmux = {
            module = "blink-cmp-tmux";
            name = "tmux";
            score_offset = -4; # Low priority

            opts = {
              all_panes = true;
              capture_history = true;
              triggered_only = true; # Only trigger on specific chars

              trigger_chars = [
                "."
              ];
            };
          };
        };
      };

      cmdline = {
        completion.menu.auto_show.__raw = ''
          function(ctx)
            return vim.fn.getcmdtype() == ":"
          end
        '';

        sources.__raw = ''
          function()
            local type = vim.fn.getcmdtype()
            if type == "/" or type == "?" then
              return { "buffer" }
            end
            if type == ":" then
              return { "cmdline", "path" }
            end
            return {}
          end
        '';
      };

      signature = {
        enabled = true;

        window = {
          border = "rounded";
        };
      };
    };
  };
}
