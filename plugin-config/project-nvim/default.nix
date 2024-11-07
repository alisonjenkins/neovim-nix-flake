{
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
}
