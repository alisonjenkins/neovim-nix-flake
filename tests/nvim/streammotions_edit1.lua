-- Differential insert mode and undo rows (chk = "edit", first half).
local h = dofile(os.getenv("TEST_DIR") .. "/harness.lua")
local L = dofile(os.getenv("TEST_DIR") .. "/streammotions_lib.lua")
L.only = L.only or { "ins.", "und." }
L.run_class(h, "edit")
h.finish()
