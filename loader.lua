-- Loader.lua: run this in your executor. It gets the modules and starts App.
local base = "https://raw.githubusercontent.com/FISHYSHUN/Repo/refs/heads/main/"
local env = (getgenv and getgenv()) or _G

-- set env.PlayerMenuDev = true before running to bypass GitHub's raw-file cache while you are editing
local bust = env.PlayerMenuDev and ("?t=" .. os.time()) or ""

-- every module file in the repo (App is the entry point)
local MODULES = {
	"Theme", "Toolkit", "Window", "Dock", "Config", "PlayerMods",
	"Vehicle", "Guard", "Extras", "Games", "PlayerSelect", "App",
}

-- replace a menu that is already running
if env.PlayerMenu then
	pcall(function() env.PlayerMenu:Destroy() end)
	env.PlayerMenu = nil
end

local function download(name)
	local url = base .. name .. ".lua" .. bust
	local lastErr
	for attempt = 1, 3 do
		local ok, body = pcall(function() return game:HttpGet(url) end)
		if ok and type(body) == "string" and body ~= "" then return body end
		lastErr = ok and "empty response" or tostring(body)
		task.wait(0.4 * attempt)
	end
	error(("[PlayerMenu] could not download '%s' (%s): %s"):format(name, url, tostring(lastErr)), 0)
end

-- fetch every file at the same time (the downloads are the slow part)
local sources, failed, pending = {}, nil, #MODULES
for _, name in MODULES do
	task.spawn(function()
		local ok, result = pcall(download, name)
		if ok then sources[name] = result else failed = failed or result end
		pending -= 1
	end)
end
while pending > 0 do task.wait() end
if failed then return warn(failed) end

local cache, loading = {}, {}
local function import(name)
	if cache[name] ~= nil then return cache[name] end
	if loading[name] then
		error(("[PlayerMenu] circular import of '%s'"):format(name), 2)
	end
	local source = sources[name]
	if not source then
		-- a name that is not in MODULES: try to fetch it directly
		local ok, body = pcall(download, name)
		if not ok then error(body, 2) end
		source = body
		sources[name] = body
	end
	local fn, err = loadstring(source, "=" .. name)
	if not fn then
		error(("[PlayerMenu] syntax error in '%s': %s"):format(name, tostring(err)), 2)
	end
	loading[name] = true
	local ok, result = pcall(fn, import)
	loading[name] = nil
	if not ok then error(result, 0) end
	if result == nil then result = true end
	cache[name] = result
	return result
end

local ok, app = pcall(import, "App")
if not ok then return warn(app) end
env.PlayerMenu = app
