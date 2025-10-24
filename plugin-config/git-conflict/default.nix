{
  git-conflict = {
    enable = true;

    lazyLoad = {
      settings = {
        event = "BufReadPost";
        cmd = [
          "GitConflictChooseOurs"
          "GitConflictChooseTheirs"
          "GitConflictChooseBoth"
          "GitConflictChooseNone"
          "GitConflictNextConflict"
          "GitConflictPrevConflict"
          "GitConflictListQf"
        ];
      };
    };
  };
}
