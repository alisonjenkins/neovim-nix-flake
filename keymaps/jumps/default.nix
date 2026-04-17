[
  {
    mode = "n";
    key = "[d";
    action.__raw = ''
      function() vim.diagnostic.jump({ count = -1 }) end
    '';
    options = {
      desc = "Jump to previous diagnostic";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "]d";
    action.__raw = ''
      function() vim.diagnostic.jump({ count = 1 }) end
    '';
    options = {
      desc = "Jump to next diagnostic";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "[r";
    action = "<cmd>BaconPrevious<cr>";
    options = {
      desc = "Bacon Previous Issue";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "]r";
    action = "<cmd>BaconNext<cr>";
    options = {
      desc = "Bacon Next Issue";
      silent = true;
    };
  }
]
