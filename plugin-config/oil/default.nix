{
  oil = {
    enable = true;

    settings = {
      delete_to_trash = true;
      skip_confirm_for_simple_edits = true;
      use_default_keymaps = false;

      keymaps = {
        "g?" = "actions.show_help";
        "<CR>" = "actions.select";
        "-" = "actions.parent";
        "_" = "actions.open_cwd";
        "`" = "actions.cd";
        "~" = "actions.tcd";
        "g." = "actions.toggle_hidden";
      };

      view_options = { show_hidden = true; };
    };
  };

}
