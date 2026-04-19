[
  {
    mode = "n";
    key = "<leader>sTD";
    action = "<cmd>TerraformDoc<CR>";
    options = {
      desc = "Terraform docs (cursor)";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>sTB";
    action = "<cmd>TerraformDocPicker<CR>";
    options = {
      desc = "Terraform docs (browse)";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>sTd";
    action = "<cmd>TofuDoc<CR>";
    options = {
      desc = "OpenTofu docs (cursor)";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>sTb";
    action = "<cmd>TofuDocPicker<CR>";
    options = {
      desc = "OpenTofu docs (browse)";
      silent = true;
    };
  }
  {
    mode = "n";
    key = "<leader>sTs";
    action = "<cmd>TerraformSearch<CR>";
    options = {
      desc = "Terraform docs (search by intent)";
      silent = true;
    };
  }
]
