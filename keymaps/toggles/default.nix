[
  {
    mode = "n";
    key = "<leader>.p";
    action = "<cmd>Pipeline<CR>";
    options = {
      desc = "CI/CD Pipelines";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>.P";
    action = "<cmd>PencilToggle<CR>";
    options = {
      desc = "Toggle Pencil";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>.t";
    action = "<cmd>Twilight<CR>";
    options = {
      desc = "Twilight";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>.T";
    action.__raw = ''
      function()
        local null_ls = require("null-ls")
        local sources = null_ls.get_sources()
        local trivy_active = false
        for _, source in ipairs(sources) do
          if source.name == "trivy" then
            trivy_active = source._disabled ~= true
            break
          end
        end
        if trivy_active then
          null_ls.disable({ name = "trivy" })
          vim.notify("Trivy diagnostics disabled", vim.log.levels.INFO)
        else
          null_ls.enable({ name = "trivy" })
          vim.notify("Trivy diagnostics enabled", vim.log.levels.INFO)
        end
      end
    '';
    options = {
      desc = "Toggle Trivy diagnostics";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>.z";
    action = "<cmd>ZenMode<CR>";
    options = {
      desc = "Zen Mode";
      silent = true;
    };
  }
]
