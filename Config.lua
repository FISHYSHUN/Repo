-- modules/Config.lua
-- Saves / loads settings. Storage is tried in this order:
--   1. folder : workspace/PlayerMenu/configs/<name>.json
--   2. flat   : workspace/PlayerMenu_<name>.json   (executors without folder functions)
--   3. memory : getgenv().PlayerMenuStore          (survives re-running the loader, not a rejoin)
-- Memory is always updated as well, so a save never silently disappears.
local import = ...

local HttpService = game:GetService("HttpService")

local ROOT = "PlayerMenu"
local FOLDER = ROOT .. "/configs"
local FLAT = "PlayerMenu_"

local env = (getgenv and getgenv()) or _G

local DIRECT = {
	writefile = writefile, readfile = readfile, isfile = isfile, makefolder = makefolder,
	isfolder = isfolder, listfiles = listfiles, delfile = delfile,
	setclipboard = setclipboard, toclipboard = toclipboard,
}

local function fs(name)
	if type(DIRECT[name]) == "function" then return DIRECT[name] end
	local ok, f = pcall(function() return env[name] end)
	if ok and type(f) == "function" then return f end
	return nil
end

local store = env.PlayerMenuStore
if type(store) ~= "table" or type(store.configs) ~= "table" then
	store = { configs = {}, autoload = nil }
	pcall(function() env.PlayerMenuStore = store end)
end

local Config = {}
local mode -- "folder" | "flat" | "memory"

local function probe(path)
	local w, r = fs("writefile"), fs("readfile")
	if not (pcall(w, path, "ok")) then return false end
	local ok, text = pcall(r, path)
	return ok and text == "ok"
end

local function detect()
	if mode then return mode end
	if not (fs("writefile") and fs("readfile")) then
		mode = "memory"
		return mode
	end
	local mk, isf = fs("makefolder"), fs("isfolder")
	if mk and isf then
		pcall(function()
			if not isf(ROOT) then mk(ROOT) end
			if not isf(FOLDER) then mk(FOLDER) end
		end)
		if probe(FOLDER .. "/_probe.txt") then
			mode = "folder"
			return mode
		end
	end
	if probe(FLAT .. "_probe.txt") then
		mode = "flat"
		return mode
	end
	mode = "memory"
	return mode
end

local function clean(name)
	name = tostring(name or "")
	name = name:gsub("[^%w _%-]", "")
	name = name:gsub("^%s+", "")
	name = name:gsub("%s+$", "")
	if name == "" then return nil end
	return name
end

local function pathFor(name)
	if detect() == "folder" then return FOLDER .. "/" .. name .. ".json" end
	return FLAT .. name .. ".json"
end

local function autoPath()
	if detect() == "folder" then return FOLDER .. "/_autoload.txt" end
	return FLAT .. "_autoload.txt"
end

local function writeFile(path, text)
	local ok, err = pcall(fs("writefile"), path, text)
	if not ok then return false, tostring(err) end
	local ok2, back = pcall(fs("readfile"), path)
	if not (ok2 and back == text) then return false, "write could not be verified" end
	return true
end

local function readFile(path)
	local isf = fs("isfile")
	if isf then
		local ok, exists = pcall(isf, path)
		if ok and not exists then return nil end
	end
	local ok, text = pcall(fs("readfile"), path)
	if ok and type(text) == "string" and text ~= "" then return text end
	return nil
end

-- text <-> table -----------------------------------------------------------------------
function Config.Encode(data)
	local ok, text = pcall(HttpService.JSONEncode, HttpService, data)
	if not ok then return nil, "could not encode settings: " .. tostring(text) end
	return text
end

function Config.Decode(text)
	if type(text) ~= "string" or text:gsub("%s", "") == "" then return nil, "nothing to read" end
	local ok, data = pcall(HttpService.JSONDecode, HttpService, text)
	if not ok or type(data) ~= "table" then return nil, "not a valid config" end
	return data
end

function Config.Copy(text)
	local copy = fs("setclipboard") or fs("toclipboard")
	if not copy then return false end
	return (pcall(copy, text))
end

-- storage info ---------------------------------------------------------------------------
function Config.Describe()
	local m = detect()
	if m == "folder" then return "Storage: files (PlayerMenu/configs)" end
	if m == "flat" then return "Storage: files (workspace root)" end
	return "Storage: memory only"
end

function Config.Available() return true end

-- save / load ------------------------------------------------------------------------------
-- returns ok, where  (where = "file" | "memory" | error text)
function Config.Save(name, data)
	name = clean(name)
	if not name then return false, "invalid name" end
	local text, err = Config.Encode(data)
	if not text then return false, err end
	store.configs[name] = text
	if detect() == "memory" then return true, "memory" end
	local ok = writeFile(pathFor(name), text)
	if ok then return true, "file" end
	return true, "memory (file write failed)"
end

function Config.Load(name)
	name = clean(name)
	if not name then return nil, "invalid name" end
	local text
	if detect() ~= "memory" then text = readFile(pathFor(name)) end
	text = text or store.configs[name]
	if not text then return nil, "no config named '" .. name .. "'" end
	local data, err = Config.Decode(text)
	if not data then return nil, "config file is corrupted (" .. tostring(err) .. ")" end
	return data
end

function Config.Exists(name)
	name = clean(name)
	if not name then return false end
	if store.configs[name] then return true end
	if detect() ~= "memory" then return readFile(pathFor(name)) ~= nil end
	return false
end

function Config.Delete(name)
	name = clean(name)
	if not name then return false end
	store.configs[name] = nil
	local del = fs("delfile")
	if del and detect() ~= "memory" then pcall(del, pathFor(name)) end
	return true
end

function Config.List()
	local seen, names = {}, {}
	local function add(n)
		if n and n:sub(1, 1) ~= "_" and not seen[n] then
			seen[n] = true
			table.insert(names, n)
		end
	end
	for n in store.configs do add(n) end
	local lf = fs("listfiles")
	local m = detect()
	if lf and m ~= "memory" then
		local ok, files = pcall(lf, m == "folder" and FOLDER or "")
		if ok and type(files) == "table" then
			for _, file in files do
				local tail = tostring(file):match("([^/\\]+)$") or ""
				if m == "folder" then
					add(tail:match("^(.+)%.json$"))
				else
					add(tail:match("^" .. FLAT .. "(.+)%.json$"))
				end
			end
		end
	end
	table.sort(names)
	return names
end

-- auto-load: remembers which config to apply on start ---------------------------------------
function Config.SetAutoload(name)
	name = name and clean(name) or nil
	store.autoload = name
	if detect() ~= "memory" then writeFile(autoPath(), name or "") end
	return true
end

function Config.GetAutoload()
	if detect() ~= "memory" then
		local text = readFile(autoPath())
		if text then return clean(text) end
	end
	return store.autoload
end

return Config
