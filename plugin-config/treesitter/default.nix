{pkgs, ...}:
{
  treesitter = let
    treesitter-powershell-grammar = pkgs.tree-sitter.buildGrammar {
      language = "powershell";
      version = "2024-07-31";
      src = pkgs.fetchFromGitHub {
        owner = "airbus-cert";
        repo = "tree-sitter-powershell";
        rev = "fc15514b2f1dbba9c58528d15a3708f89eda6a01";
        hash = "sha256-StVnRNM0HPevLSRDIDr+Sakjo+NqXYWPPUFjI29Cowo=";
      };
      meta.homepage = "https://github.com/airbus-cert/tree-sitter-powershell/";
    };
    treesitter-vhdl-grammar = pkgs.tree-sitter.buildGrammar {
      language = "vhdl";
      version = "2024-07-18";
      src = pkgs.fetchFromGitHub {
        owner = "jpt13653903";
        repo = "tree-sitter-vhdl";
        rev = "4ab3e251eae8890a020d083d00acd1b8c2653c07";
        hash = "sha256-egNgZ1GgRNvIdH08cf6V83bMeOECs23yiV5RzcXZENg=";
      };
      meta.homepage = "https://github.com/jpt13653903/tree-sitter-vhdl";
    };

    treesitter-vrl-grammar = pkgs.tree-sitter.buildGrammar {
      language = "vrl";
      version = "2024-07-18";
      src = pkgs.fetchFromGitHub {
        owner = "belltoy";
        repo = "tree-sitter-vrl";
        rev = "274b3ce63f72aa8ffea18e7fc280d3062d28f0ba";
        hash = "sha256-R+wuG8UkvGA11uTiiUAdzzgjRv1ik4W+qh3YwIREUd4=";
      };
      meta.homepage = "https://github.com/belltoy/tree-sitter-vrl";
    };
  in {
    enable = true;

    grammarPackages =
      pkgs.vimPlugins.nvim-treesitter.passthru.allGrammars
      ++ [
        treesitter-powershell-grammar
        treesitter-vhdl-grammar
        treesitter-vrl-grammar
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

        incremental_selection = { enable = false; };

        indent = { enable = false; };
      };
    };
  }
