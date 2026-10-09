-- Loader.lua : run this ONE file. It loads every module from your executor's workspace folder
-- (no internet, no GitHub).
--
-- Setup:
--   1. In your executor's workspace folder, create a folder called  PlayerMenu
--   2. Put ALL the .lua files in it: App, Behavior, Controls, Dock, Loader, PlayerMods, Skins,
--      Theme, Toolkit, Window   (flat, no sub-folders; Window.lua etc. exactly as in your repo)
--   3. Execute:
--        loadstring(readfile("PlayerMenu/Loader.lua"))()

local FOLDER = "PlayerMenu"

local env = (getgenv and getgenv()) or _G

-- running it twice replaces the old menu instead of stacking a second one
if env.PlayerMenu then
	pcall(function() env.PlayerMenu:Destroy() end)
	env.PlayerMenu = nil
end

local cache = {}

local function import(name)
	if cache[name] ~= nil then return cache[name] end

	local path = FOLDER .. "/" .. name .. ".lua"
	if not (isfile and isfile(path)) then
		error(("[PlayerMenu] missing file '%s' (put it in your executor's workspace folder)"):format(path), 2)
	end

	local fn, err = loadstring(readfile(path), "=" .. name)
	if not fn then
		error(("[PlayerMenu] syntax error in '%s': %s"):format(name, tostring(err)), 2)
	end

	local result = fn(import) -- every module starts with:  local import = ...
	cache[name] = result
	return result
end

local ok, app = pcall(import, "App")
if not ok then
	warn(app)
	return
end

env.PlayerMenu = app
return app
