{ pkgs }: {
  remote-nvim = {
    enable = true;

    settings = {
      devpod = {
        binary = "${pkgs.devpod}/bin/devpod";
      };
    };

    lazyLoad = {
      settings = {
        cmd = [
          "RemoteInfo"
          "RemoteLog"
          "RemoteStart"
          "RemoteStop"
          "RemoteCleanup"
          "RemoteConfigDel"
        ];
      };
    };
  };
}
