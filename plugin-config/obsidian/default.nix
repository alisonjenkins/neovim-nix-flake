{
  obsidian = {
    enable = true;

    settings = {
      legacy_commands = false;
      new_notes_location = "current_dir";

      completion = {
        blink = true;
        min_chars = 2;
      };

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
