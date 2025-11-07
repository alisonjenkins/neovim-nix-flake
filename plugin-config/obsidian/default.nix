{
  obsidian = {
    enable = true;

    lazyLoad.settings = {
      cmd = [ "Obsidian" ];
      ft = [ "markdown" ];
    };

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

      workspaces.__raw = ''
      {
        unpack(vim.fn.isdirectory(vim.fn.expand('~') .. '/obsidian') and {
          {
            name = "startup",
            path = "~/obsidian",
          }
        } or {}),
        {
          name = "no-vault",
          path = function()
            return assert(vim.fs.dirname(vim.api.nvim_buf_get_name(0)))
          end,
          overrides = {
            notes_subdir = vim.NIL,
            new_notes_location = "current_dir",
            templates = {
              folder = vim.NIL,
            },
            frontmatter = {
              enabled = true,
            },
          },
        },
      }
      '';
    };
  };
}
