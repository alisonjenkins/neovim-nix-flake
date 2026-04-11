{ pkgs, ... }: {
  rustaceanvim = {
    enable = true;

    settings = {
      dap = {
        adapter.__raw = ''
          {
            type = "executable",
            command = "${pkgs.vscode-extensions.vadimcn.vscode-lldb}/share/vscode/extensions/vadimcn.vscode-lldb/adapter/codelldb",
            args = {
              "--liblldb",
              "${pkgs.vscode-extensions.vadimcn.vscode-lldb}/share/vscode/extensions/vadimcn.vscode-lldb/lldb/lib/liblldb.so",
            },
          }
        '';

        configuration = {
          sourceLanguages = [ "rust" ];
          initCommands.__raw = ''
            function()
              -- Load Rust pretty-printers from the rustc sysroot
              local rustc_sysroot = vim.fn.trim(vim.fn.system("rustc --print sysroot"))
              local script = rustc_sysroot .. "/lib/rustlib/etc/lldb_lookup.py"
              local commands = rustc_sysroot .. "/lib/rustlib/etc/lldb_commands"

              local cmds = {}
              if vim.fn.filereadable(script) == 1 then
                table.insert(cmds, "command script import " .. script)
              end
              if vim.fn.filereadable(commands) == 1 then
                for line in io.lines(commands) do
                  if line and line ~= "" then
                    table.insert(cmds, line)
                  end
                end
              end
              return cmds
            end
          '';
        };
      };

      server = {
        # Route rust-analyzer through lspmux so multiple Neovim instances share one instance
        cmd.__raw = ''{ "${pkgs.lspmux}/bin/lspmux", "client", "--server-path", "rust-analyzer" }'';

        default_settings = {
          rust-analyzer = {
            files = { excludeDirs = [ ".direnv" ]; };
          };
        };
      };
    };
  };
}
