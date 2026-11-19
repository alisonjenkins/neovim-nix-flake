-- Differential motions: the stream viewer against stock Neovim (rows with chk = "nav").
local h = dofile(os.getenv("TEST_DIR") .. "/harness.lua")
dofile(os.getenv("TEST_DIR") .. "/streammotions_lib.lua").run_class(h, "nav")
h.finish()
