-- modules/Config.lua
-- Saves / loads settings as JSON files in your executor's workspace:
--   workspace/PlayerMenu/configs/<name>.json
-- Needs an executor with writefile / readfile / isfile / makefolder / listfiles.
local import = ...

local HttpService = game:GetService("HttpService")

local ROOT = "PlayerMenu"
local FOLDER = ROOT .. "/configs"
local AUTOLOAD = FOLDER .. "/_autoload.txt"

local Config = {}

function Config.Available()
	return writefile ~= nil and readfile ~= nil and isfile ~= nil
		and makefolder ~= nil and isfolder ~= nil
end

local function ensureFolders()
	if not isfolder(ROOT) then makefolder(ROOT) end
	if not isfolder(FOLDER) then makefolder(FOLDER) end
end

local function clean(name)
	name = tostring(name or ""):gsub("[^%w _%-]", ""):gsub("^%s+", ""):gsub("%s+$", "")
	return name ~= "" and name or nil
end

local function pathFor(name)
	return FOLDER .. "/" .. name .. ".json"
end

function Config.Save(name, data)
	if not Config.Available() then return false, "this executor has no file functions" end
	name = clean(name)
	if not name then return false, "invalid name" end
	local ok, err = pcall(function()
		ensureFolders()
		writefile(pathFor(name), HttpService:JSONEncode(data))
	end)
	return ok, err
end

function Config.Load(name)
	if not Config.Available() then return nil, "this executor has no file functions" end
	name = clean(name)
	if not name then return nil, "invalid name" end
	local path = pathFor(name)
	if not isfile(path) then return nil, "no config named '" .. name .. "'" end
	local ok, result = pcall(function()
		return HttpService:JSONDecode(readfile(path))
	end)
	if not ok then return nil, "config file is corrupted" end
	return result
end

function Config.Delete(name)
	if not Config.Available() then return false end
	name = clean(name)
	if not name then return false end
	local path = pathFor(name)
	if not isfile(path) then return false end
	if delfile then
		return pcall(delfile, path)
	end
	return false
end

function Config.List()
	local names = {}
	if not (Config.Available() and listfiles and isfolder(FOLDER)) then return names end
	local ok, files = pcall(listfiles, FOLDER)
	if not ok then return names end
	for _, file in files do
		local name = tostring(file):match("([^/\\]+)%.json$")
		if name then table.insert(names, name) end
	end
	table.sort(names)
	return names
end

-- Auto-load: remembers which config to apply on start --------------------------------
function Config.SetAutoload(name)
	if not Config.Available() then return false end
	name = name and clean(name) or nil
	local ok = pcall(function()
		ensureFolders()
		writefile(AUTOLOAD, name or "")
	end)
	return ok
end

function Config.GetAutoload()
	if not (Config.Available() and isfile(AUTOLOAD)) then return nil end
	local ok, text = pcall(readfile, AUTOLOAD)
	if not ok then return nil end
	return clean(text)
end

return Config
