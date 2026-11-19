-- Differential visual mode and operator-with-motion rows (chk = "txt", first half).
local h = dofile(os.getenv("TEST_DIR") .. "/harness.lua")
local L = dofile(os.getenv("TEST_DIR") .. "/streammotions_lib.lua")
L.only = L.only or { "vis.", "opr.motion", "opr.line", "opr.char", "opr.registers" }
L.run_class(h, "txt")
h.finish()
