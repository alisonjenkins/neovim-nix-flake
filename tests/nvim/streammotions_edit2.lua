-- Differential ex range, substitute and file format rows (chk = "edit", second half).
local h = dofile(os.getenv("TEST_DIR") .. "/harness.lua")
local L = dofile(os.getenv("TEST_DIR") .. "/streammotions_lib.lua")
L.only = L.only or { "exr.", "sub.", "uni." }
L.run_class(h, "edit")
h.finish()
