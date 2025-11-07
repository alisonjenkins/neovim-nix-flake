{ pkgs }: {
  kulala = {
    enable = true;
    package = pkgs.stable.vimPlugins.kulala-nvim;

    settings = {
      curl_path = "${pkgs.curl}/bin/curl";
      contenttypes = {
        "application/json" = {
          ft = "json";
          formatter = [ "jq" "." ];
          pathresolver = ''require("kulala.parser.jsonpath").parse'';
        };
        "application/xml" = {
          ft = "xml";
          formatter = [ "${pkgs.libxml2}/bin/xmllint" "--format" "-" ];
          pathresolver = [ "${pkgs.libxml2}/bin/xmllint" "--xpath" "{{path}}" "-" ];
        };
        "text/html" = {
          ft = "html";
          formatter = [ "${pkgs.libxml2}/bin/xmllint" "--format" "--html" "-" ];
          pathresolver = { };
        };
      };
    };

    lazyLoad = {
      enable = true;

      settings = {
        ft = [
          "http"
        ];
      };
    };
  };
}
