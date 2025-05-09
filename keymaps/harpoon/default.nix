[
  {
    mode = "n";
    key = "<leader>ha";
    action = ''<cmd>lua require("harpoon.mark").add_file()<CR>'';
    options = {
      desc = "Harpoon Add";
      silent = true;
    };
  }
  # {
  #   mode = "n";
  #   key = "<leader>hh";
  #   action = ''<cmd>Telescope harpoon marks<CR>'';
  #   options = {
  #     desc = "Harpoon Telescope Marks";
  #     silent = true;
  #   };
  # }
  # {
  #   mode = "n";
  #   key = "<leader>hh";
  #   action = ''<cmd>Telescope harpoon marks<CR>'';
  #   options = {
  #     desc = "Harpoon Telescope Marks";
  #     silent = true;
  #   };
  # }
  {
    mode = "n";
    key = "<leader>hn";
    action = ''<cmd>lua require("harpoon.ui").nav_next()<CR>'';
    options = {
      desc = "Harpoon Next Mark";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>hp";
    action = ''<cmd>lua require("harpoon.ui").nav_prev()<CR>'';
    options = {
      desc = "Harpoon Previous Mark";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>hs";
    action = ''<cmd>lua require("harpoon.ui").nav_file(1)<CR>'';
    options = {
      desc = "Harpoon Mark 1";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>hd";
    action = ''<cmd>lua require("harpoon.ui").nav_file(2)<CR>'';
    options = {
      desc = "Harpoon Mark 2";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>hf";
    action = ''<cmd>lua require("harpoon.ui").nav_file(3)<CR>'';
    options = {
      desc = "Harpoon Mark 3";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>hg";
    action = ''<cmd>lua require("harpoon.ui").nav_file(4)<CR>'';
    options = {
      desc = "Harpoon Mark 4";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>hm";
    action = ''<cmd>lua require("harpoon.ui").toggle_quick_menu()<CR>'';
    options = {
      desc = "Harpoon Menu";
      silent = true;
    };
  }
]
