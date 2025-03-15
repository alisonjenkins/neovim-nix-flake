[
  {
    mode = "n";
    key = "<leader>zc";
    action = "<cmd>lcd ~/git/zettelkasten | ZkCd<cr>";
    options = {
      desc = "cd into the notebook root";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>zn";
    action = "<cmd>lcd ~/git/zettelkasten | ZkNotes<cr>";
    options = {
      desc = "Open the Notes Picker";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>zN";
    action = "<cmd>lcd ~/git/zettelkasten | ZkNew<cr>";
    options = {
      desc = "Create and edit a new note";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>zd";
    action = "<cmd>lcd ~/git/zettelkasten | ZkNew { group = \"daily\" }<cr>";
    options = {
      desc = "Create and edit a new note";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>zb";
    action = "<cmd>lcd ~/git/zettelkasten | ZkBacklinks<cr>";
    options = {
      desc = "Opens a notes picker for the backlinks of the current buffer";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>zl";
    action = "<cmd>lcd ~/git/zettelkasten | ZkLinks<cr>";
    options = {
      desc = "Opens a notes picker for the outbound links of the current buffer";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>zi";
    action = "<cmd>lcd ~/git/zettelkasten | ZkInsertLink<cr>";
    options = {
      desc = "Inserts a link at the cursor location or around the selected text.";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>zt";
    action = "<cmd>lcd ~/git/zettelkasten | ZkTags<cr>";
    options = {
      desc = "Opens a notes picker, filters for notes with the selected tags";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>zo";
    action =
      "<cmd>lcd ~/git/zettelkasten | ZkNotes { sort = { 'modified' }, match = { vim.fn.input('Search: ') } }<cr>";
    options = {
      desc = "Find notes by modification date";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>zI";
    action = "<cmd>lcd ~/git/zettelkasten | ZkIndex<cr>";
    options = {
      desc = "Indexes the notebook";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>zw";
    action = "<cmd>lcd ~/git/zettelkasten | ZkNew { group = \"weekly\" }<cr>";
    options = {
      desc = "Create and edit a new note";
      silent = true;
    };
  }
]
