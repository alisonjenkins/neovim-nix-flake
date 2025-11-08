{
  oil = {
    enable = true;

    lazyLoad.settings = {
      keys = [ "-" ];
      cmd = [ "Oil" ];
    };

    settings = {
      delete_to_trash = true;
      skip_confirm_for_simple_edits = true;
      use_default_keymaps = false;
      view_options = { show_hidden = true; };

      keymaps = {
        "g?" = "actions.show_help";
        "<CR>" = "actions.select";
        "-" = "actions.parent";
        "_" = "actions.open_cwd";
        "`" = "actions.cd";
        "~" = "actions.tcd";
        "g." = "actions.toggle_hidden";
      };

      win_options = {
        signcolumn = "yes:2";
      };
    };
  };

}
