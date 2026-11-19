-- Scale probes on a 2 GB many-line file and a 1 GB sparse single line (see streammotions_scale.lua).
STREAM_SCALE = "big"
dofile(os.getenv("TEST_DIR") .. "/streammotions_scale.lua")
