[
  # Navigation — go-to actions via snacks picker
  {
    mode = "n";
    key = "gd";
    action.__raw = ''
      function() require("snacks").picker.lsp_definitions() end
    '';
    options = {
      desc = "Goto Definition";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "gD";
    action.__raw = ''
      function() require("snacks").picker.lsp_declarations() end
    '';
    options = {
      desc = "Goto Declaration";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "gy";
    action.__raw = ''
      function() require("snacks").picker.lsp_type_definitions() end
    '';
    options = {
      desc = "Goto Type Definition";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "gr";
    action.__raw = ''
      function() require("snacks").picker.lsp_references() end
    '';
    options = {
      desc = "References";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "gI";
    action.__raw = ''
      function() require("snacks").picker.lsp_implementations() end
    '';
    options = {
      desc = "Goto Implementation";
      silent = true;
    };
  }

  # Hover / signature help
  {
    mode = "n";
    key = "K";
    action.__raw = ''
      function() vim.lsp.buf.hover() end
    '';
    options = {
      desc = "Hover Documentation";
      silent = true;
    };
  }
  {
    mode = "i";
    key = "<C-k>";
    action.__raw = ''
      function() vim.lsp.buf.signature_help() end
    '';
    options = {
      desc = "Signature Help";
      silent = true;
    };
  }

  # Code actions / format
  {
    mode = [ "n" "v" ];
    key = "<leader>lc";
    action.__raw = ''
      function() vim.lsp.buf.code_action() end
    '';
    options = {
      desc = "Code Action";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>lf";
    action.__raw = ''
      function() require("conform").format({ async = true, lsp_fallback = true }) end
    '';
    options = {
      desc = "Format Buffer";
      silent = true;
    };
  }

  # Finder / call hierarchy via snacks picker
  {
    mode = "n";
    key = "<leader>lff";
    action.__raw = ''
      function() require("snacks").picker.lsp_references() end
    '';
    options = {
      desc = "Find References";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>lfi";
    action.__raw = ''
      function() require("snacks").picker.lsp_implementations() end
    '';
    options = {
      desc = "Find Implementations";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>lfI";
    action.__raw = ''
      function() require("snacks").picker.lsp_incoming_calls() end
    '';
    options = {
      desc = "Find Incoming Calls";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>lfo";
    action.__raw = ''
      function() require("snacks").picker.lsp_outgoing_calls() end
    '';
    options = {
      desc = "Find Outgoing Calls";
      silent = true;
    };
  }

  # Inlay hints toggle
  {
    mode = "n";
    key = "<leader>li";
    action.__raw = ''
      function()
        vim.lsp.inlay_hint.enable(
          not vim.lsp.inlay_hint.is_enabled({ bufnr = 0 }),
          { bufnr = 0 }
        )
      end
    '';
    options = {
      desc = "Toggle Inlay Hints";
      silent = true;
    };
  }

  # Navbuddy
  {
    mode = "n";
    key = "<leader>ln";
    action = "<cmd>Navbuddy<cr>";
    options = {
      desc = "Navbuddy";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>lo";
    action = "<cmd>Navbuddy<cr>";
    options = {
      desc = "LSP Outline (Navbuddy)";
      silent = true;
    };
  }

  # Peek (snacks preview pane serves the same purpose)
  {
    mode = "n";
    key = "<leader>lpd";
    action.__raw = ''
      function() require("snacks").picker.lsp_definitions() end
    '';
    options = {
      desc = "Peek Definition";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>lpt";
    action.__raw = ''
      function() require("snacks").picker.lsp_type_definitions() end
    '';
    options = {
      desc = "Peek Type Definition";
      silent = true;
    };
  }

  # Rename — inc-rename with live preview when the server supports it,
  # otherwise fall back to vim.lsp.buf.rename() (shows Neovim's standard error
  # if no server has rename capability, e.g. terraform-ls which does not implement
  # textDocument/rename as of v0.38.6; see hashicorp/terraform-ls#1155).
  {
    mode = "n";
    key = "<leader>lr";
    action.__raw = ''
      function()
        local clients = vim.lsp.get_clients({ bufnr = 0, method = "textDocument/rename" })
        if #clients > 0 then
          vim.api.nvim_feedkeys(":IncRename " .. vim.fn.expand("<cword>"), "n", false)
        else
          vim.lsp.buf.rename()
        end
      end
    '';
    options = {
      desc = "Rename";
      silent = true;
    };
  }

  # Symbols
  {
    mode = "n";
    key = "<leader>ls";
    action = "<cmd>lua require('snacks').picker.lsp_symbols()<cr>";
    options = {
      desc = "LSP Symbols";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>lS";
    action = "<cmd>lua require('snacks').picker.lsp_workspace_symbols()<cr>";
    options = {
      desc = "LSP Workspace Symbols";
      silent = true;
    };
  }

  # Bacon (Rust background checker)
  {
    mode = "n";
    key = "<leader>lbl";
    action = "<cmd>BaconList<cr>";
    options = {
      desc = "Bacon List";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>lbs";
    action = "<cmd>BaconShow<cr>";
    options = {
      desc = "Bacon Show";
      silent = true;
    };
  }

  # Trouble — diagnostic lists
  {
    mode = "n";
    key = "<leader>xx";
    action = "<cmd>Trouble diagnostics toggle<cr>";
    options = {
      desc = "Workspace Diagnostics (Trouble)";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>xb";
    action = "<cmd>Trouble diagnostics toggle filter.buf=0<cr>";
    options = {
      desc = "Buffer Diagnostics (Trouble)";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>xl";
    action = "<cmd>Trouble loclist toggle<cr>";
    options = {
      desc = "Location List (Trouble)";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>xq";
    action = "<cmd>Trouble qflist toggle<cr>";
    options = {
      desc = "Quickfix List (Trouble)";
      silent = true;
    };
  }

  # schema-companion (yaml/helm schema selection)
  {
    mode = "n";
    key = "<leader>ys";
    action.__raw = ''function() require("schema-companion").select_schema() end'';
    options = {
      desc = "Select YAML schema";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>ym";
    action.__raw = ''function() require("schema-companion").select_matching_schema() end'';
    options = {
      desc = "Select matching YAML schema";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>yi";
    action.__raw = ''
      function()
        local current = require("schema-companion").get_current_schemas()
        if not current then
          vim.notify("schema-companion: no schema for buffer", vim.log.levels.INFO)
          return
        end
        vim.notify(current, vim.log.levels.INFO, { title = "schema-companion" })
      end
    '';
    options = {
      desc = "Show current YAML schema";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>yr";
    action.__raw = ''function() require("schema-companion").match() end'';
    options = {
      desc = "Re-match YAML schema";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>yI";
    action.__raw = ''
      function()
        local matched = require("schema-companion.schema").match(0)
        if not matched or #matched == 0 then
          vim.notify("schema-companion: no schema matched", vim.log.levels.WARN)
          return
        end
        local uri = matched[1].uri
        if not uri then
          vim.notify("schema-companion: matched schema has no URI", vim.log.levels.WARN)
          return
        end
        local first = vim.api.nvim_buf_get_lines(0, 0, 1, false)[1] or ""
        if first:match("^#%s*yaml%-language%-server:") then
          vim.api.nvim_buf_set_lines(0, 0, 1, false, { "# yaml-language-server: $schema=" .. uri })
        else
          vim.api.nvim_buf_set_lines(0, 0, 0, false, { "# yaml-language-server: $schema=" .. uri })
        end
        vim.notify("inserted modeline: " .. uri, vim.log.levels.INFO, { title = "schema-companion" })
      end
    '';
    options = {
      desc = "Insert YAML schema modeline";
      silent = true;
    };
  }
]
