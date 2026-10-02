#!/usr/bin/env lua

-- First MMD assembly pass for Sonic 3. This keeps all original code and data
-- so its size can be measured before the game is divided into loadable modules.
local common = require "build_tools.lua.common"

common.build_rom_and_handle_failure(
	"SegaCD/generated/s3-mmd-full",
	"SegaCD/build/s3-mmd-full",
	"-D MMD_Enabled=1",
	"-p=0 -z=0,kosinski,Size_of_Snd_driver_guess,after -z=1300,kosinski,Size_of_Snd_driver2_guess,before",
	false,
	"https://github.com/sonicretro/skdisasm"
)

common.exit()
