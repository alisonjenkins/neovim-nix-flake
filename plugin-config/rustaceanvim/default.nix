{ pkgs, ... }: {
  rustaceanvim = {
    enable = true;

    settings = {
      dap = {
        adapter = {
          host = "127.0.0.1";
          port = ''''${port}'';
          type = "server";

          executable = {
            command = ''${pkgs.stable.vscode-extensions.vadimcn.vscode-lldb}/share/vscode/extensions/vadimcn.vscode-lldb/adapter/codelldb'';
            args = [
              "--liblldb"
              ''${pkgs.stable.vscode-extensions.vadimcn.vscode-lldb}/share/vscode/extensions/vadimcn.vscode-lldb/lldb/lib/liblldb.so''
              "--port"
              ''''${port}''
            ];
          };
        };
      };

      server = {
        default_settings = {
          rust-analyzer = {
            files = { excludeDirs = [ ".direnv" ]; };
          };
        };
      };
    };
  };
}
