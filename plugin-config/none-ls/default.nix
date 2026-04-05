{
  none-ls = {
    enable = true;

    sources = {
      diagnostics = {
        terraform_validate.enable = true;
        tfsec.enable = true;
        trivy.enable = true;
      };
    };
  };
}
