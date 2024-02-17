[
  {
    mode = "n";
    key = "<leader>zc";
    action = "<cmd>ZkCd<cr>";
    options = {
      desc = "cd into the notebook root";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>zn";
    action = "<cmd>ZkNotes<cr>";
    options = {
      desc = "Open the Notes Picker";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>zN";
    action = "<cmd>ZkNew<cr>";
    options = {
      desc = "Create and edit a new note";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>zb";
    action = "<cmd>ZkBacklinks<cr>";
    options = {
      desc = "Opens a notes picker for the backlinks of the current buffer";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>zl";
    action = "<cmd>ZkLinks<cr>";
    options = {
      desc = "Opens a notes picker for the outbound links of the current buffer";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>zi";
    action = "<cmd>ZkInsertLink<cr>";
    options = {
      desc = "Inserts a link at the cursor location or around the selected text.";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>zt";
    action = "<cmd>ZkTags<cr>";
    options = {
      desc = "Opens a notes picker, filters for notes with the selected tags";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>zo";
    action =
      "<cmd>ZkNotes { sort = { 'modified' }, match = { vim.fn.input('Search: ') } }<cr>";
    options = {
      desc = "Find notes by modification date";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>zI";
    action = "<cmd>ZkIndex<cr>";
    options = {
      desc = "Indexes the notebook";
      silent = true;
    };
  }
]
