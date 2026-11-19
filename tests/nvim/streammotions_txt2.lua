-- Differential put, repeat, macro, join, increment and text object rows (chk = "txt", second half).
local h = dofile(os.getenv("TEST_DIR") .. "/harness.lua")
local L = dofile(os.getenv("TEST_DIR") .. "/streammotions_lib.lua")
L.only = L.only or { "opr.put", "opr.dot", "opr.macro", "opr.bigyank", "opr.join", "opr.incr", "txo." }
L.run_class(h, "txt")
h.finish()
