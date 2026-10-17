-- Differential search rows (chk = "search").
local h = dofile(os.getenv("TEST_DIR") .. "/harness.lua")
dofile(os.getenv("TEST_DIR") .. "/streammotions_lib.lua").run_class(h, "search")
h.finish()
