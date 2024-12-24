{ pkgs }: {
  dap-lldb = {
    enable = true;

    settings = {
      codelldb_path = "${pkgs.vscode-extensions.vadimcn.vscode-lldb}/share/vscode/extensions/vadimcn.vscode-lldb/adapter/codelldb";
    };
  };
}
