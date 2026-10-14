{
  none-ls = {
    enable = true;

    lazyLoad.settings.event = [ "DeferredUIEnter" ];

    sources = {
      diagnostics = {
        trivy.enable = true;
      };
    };
  };
}
