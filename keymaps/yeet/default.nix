[
  {
    mode = "n";
    key = "<leader>yr";
    action.__raw = ''
      function()
        require('yeet').execute()
      end
    '';
    options = {
      desc = "Yeet: run command";
      silent = true;
    };
  }
  {
    mode = "v";
    key = "<leader>yr";
    action.__raw = ''
      function()
        require('yeet').execute_selection()
      end
    '';
    options = {
      desc = "Yeet: run visual selection";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>yc";
    action.__raw = ''
      function()
        require('yeet').list_cmd()
      end
    '';
    options = {
      desc = "Yeet: browse command cache";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>yt";
    action.__raw = ''
      function()
        require('yeet').select_target()
      end
    '';
    options = {
      desc = "Yeet: select target";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>yo";
    action.__raw = ''
      function()
        require('yeet').toggle_post_write()
      end
    '';
    options = {
      desc = "Yeet: toggle auto-run on save";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>ye";
    action.__raw = ''
      function()
        require('yeet').setqflist()
      end
    '';
    options = {
      desc = "Yeet: send output to quickfix";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>yi";
    action.__raw = ''
      function()
        require('yeet').execute({ interrupt_before_yeet = true, clear_before_yeet = false })
      end
    '';
    options = {
      desc = "Yeet: interrupt and re-run";
      silent = true;
    };
  }
]
