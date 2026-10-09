-- Loader.lua : the ONLY file you execute.
--
--   loadstring(game:HttpGet("https://raw.githubusercontent.com/USER/REPO/main/Loader.lua"))()
--
-- It downloads every file in /modules on demand, runs each one as its own chunk and hands it an
-- `import` function (so modules never need `require(script.X)`). Every module is its own function,
-- so none of them comes close to the per-function local / upvalue limits.

local REPO_BASE = "https://raw.githubusercontent.com/FISHYSHUN/Repo/main/" -- <-- EDIT: your user / repo / branch

local env = (getgenv and getgenv()) or _G
local base = env.PlayerMenuBase or REPO_BASE -- optional override: getgenv().PlayerMenuBase = "https://.../"

-- running it twice replaces the old menu instead of stacking a second one
if env.PlayerMenu then
	pcall(function() env.PlayerMenu:Destroy() end)
	env.PlayerMenu = nil
end

local cache = {}

local function import(name)
	if cache[name] ~= nil then return cache[name] end

	local url = base .. "modules/" .. name .. ".lua"
	local ok, source = pcall(function() return game:HttpGet(url) end)
	if not ok or type(source) ~= "string" or source == "" then
		error(("[PlayerMenu] could not download '%s' (%s)"):format(name, url), 2)
	end

	local fn, err = loadstring(source, "=" .. name)
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
