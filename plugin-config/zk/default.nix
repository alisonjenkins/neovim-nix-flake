{
  zk = {
    enable = true;

    settings = { picker = "telescope"; };

    lazyLoad = {
      settings = {
        cmd = [
          "ZkIndex"
          "ZkNew"
          "ZkNewFromTitleSelection"
          "ZkNewFromContentSelection"
          "ZkNotes"
          "ZkTags"
          "ZkMatch"
          "ZkLinks"
          "ZkBacklinks"
          "ZkInsertLink"
          "ZkInsertLinkAtSelection"
        ];
        keys = [
          "<leader>z"
        ];
      };
    };
  };
}
