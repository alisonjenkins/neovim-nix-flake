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

      frontmatter.func.__raw = ''
        function (note)
          -- Add the title of the note as an alias.
          if note.title then
            note:add_alias(note.title)
          end

          local out = { id = note.id, aliases = note.aliases, tags = note.tags }

          if note.metadata ~= nil and not vim.tbl_isempty(note.metadata) then
            for k, v in pairs(note.metadata) do
              out[k] = v
            end
          end

          return out
        end
      '';

      workspaces = [
        {
          name = "startup";
          path = "~/obsidian/";
        }
      ];
    };
  };
}
