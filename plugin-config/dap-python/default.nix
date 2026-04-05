{ pkgs }: {
  dap-python = {
    enable = true;

    settings = {
      adapterPythonPath = "${pkgs.python3.withPackages (ps: [ ps.debugpy ])}/bin/python3";
    };
  };
}
