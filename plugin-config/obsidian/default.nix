{
  obsidian = {
    enable = true;

    settings = {
      completion = {
        blink = true;
        min_chars = 2;
      };
      new_notes_location = "current_dir";
      workspaces = [
        {
          name = "work";
          path = "~/obsidian/work";
        }
        {
          name = "startup";
          path = "~/obsidian/startup";
        }
      ];
    };
  };
}
