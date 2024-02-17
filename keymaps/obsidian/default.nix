[
  # { *TODO* Figure out how to parameterise this
  #   mode = "n";
  #   key = "<leader>odt";
  #   action = "<cmd>ObsidianTags<cr>";
  #   options = {
  #     desc = "Get a location list of all occurrences of the given tags.";
  #     silent = true;
  #   };
  # }
  {
    mode = "n";
    key = "<leader>on";
    action = "<cmd>ObsidianNew<cr>";
    options = {
      desc = "Create new Obsidian note";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>oo";
    action = "<cmd>ObsidianOpen<cr>";
    options = {
      desc = "Open Obsidian Note in Obsidian";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>os";
    action = "<cmd>ObsidianQuickSwitch<cr>";
    options = {
      desc = "Search for Obsidian Note";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>ol";
    action = "<cmd>ObsidianFollowLink<cr>";
    options = {
      desc = "Follow link";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>ob";
    action = "<cmd>ObsidianBacklinks<cr>";
    options = {
      desc = "Search for Obsidian Backlinks for the current note";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>odd";
    action = "<cmd>ObsidianToday<cr>";
    options = {
      desc = "Open or Create a Daily Note for Today";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>ody";
    action = "<cmd>ObsidianYesterday<cr>";
    options = {
      desc = "Open or Create a Daily Note for Yesterday";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>odt";
    action = "<cmd>ObsidianTomorrow<cr>";
    options = {
      desc = "Open or Create a Daily Note for Tomorrow";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>ot";
    action = "<cmd>ObsidianTemplate<cr>";
    options = {
      desc = "Insert a template from the templates folder, selecting from a list using your preferred picker.";
      silent = true;
    };
  }
  {
    mode = "v";
    key = "<leader>oll";
    action = "<cmd>ObsidianLink<cr>";
    options = {
      desc = "Link an inline visual selection of text to a note.";
      silent = true;
    };
  }
  {
    mode = "v";
    key = "<leader>oll";
    action = "<cmd>ObsidianLinkNew<cr>";
    options = {
      desc = "To create a new note and link it to an inline visual selection of text.";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>olL";
    action = "<cmd>ObsidianLinks<cr>";
    options = {
      desc = "List all links in the current buffer in a picker window.";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>ow";
    action = "<cmd>ObsidianWorkspace<cr>";
    options = {
      desc = "Switch to another Obsidian Workspace";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>oe";
    action = "<cmd>ObsidianPasteImg<cr>";
    options = {
      desc = "Paste an image from the clipboard into the note at the cursor position by saving it to the vault and adding a markdown image link.";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>or";
    action = "<cmd>ObsidianRename<cr>";
    options = {
      desc = "Rename the note of the current buffer or reference under the cursor, updating all backlinks across the vault.";
      silent = true;
    };
  }
]
