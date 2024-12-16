''
  vim.api.nvim_buf_set_keymap(
    0,
    "n",
    "ghr",
    "<cmd>lua require('kulala').run()<cr>",
    { noremap = true, silent = true, desc = "Execute http request" }
  )

  vim.api.nvim_buf_set_keymap(
    0,
    "n",
    "ghi",
    "<cmd>lua require('kulala').inspect()<cr>",
    { noremap = true, silent = true, desc = "Inspect http request" }
  )

  vim.api.nvim_buf_set_keymap(
    0,
    "n",
    "ghi",
    "<cmd>lua require('kulala').toggle_view()<cr>",
    { noremap = true, silent = true, desc = "Toggle http request body and headers" }
  )

  vim.api.nvim_buf_set_keymap(
    0,
    "n",
    "ghy",
    "<cmd>lua require('kulala').copy()<cr>",
    { noremap = true, silent = true, desc = "Yank http request as curl" }
  )

  vim.api.nvim_buf_set_keymap(
    0,
    "n",
    "ghp",
    "<cmd>lua require('kulala').from_curl()<cr>",
    { noremap = true, silent = true, desc = "Paste curl as http request" }
  )

  vim.api.nvim_buf_set_keymap(
    0,
    "n",
    "[",
    "<cmd>lua require('kulala').jump_prev()<cr>",
    { noremap = true, silent = true, desc = "Jump to previous http request" }
  )

  vim.api.nvim_buf_set_keymap(
    0,
    "n",
    "]",
    "<cmd>lua require('kulala').jump_next()<cr>",
    { noremap = true, silent = true, desc = "Jump to next http request" }
  )
''
