-- modules/Games.lua
-- Which game are we in? Add an entry to List to support another one.
-- The IDs are from memory: if a game is not recognised, check game.PlaceId / game.GameId and fix the entry.
local import = ...

local MarketplaceService = game:GetService("MarketplaceService")

local Games = {}

Games.List = {
	{ Id = "MM2", Name = "Murder Mystery 2", PlaceIds = { 142823291 }, UniverseIds = { 66654135 }, NameHint = "murder mystery" },
}

function Games.Detect()
	for _, g in Games.List do
		if table.find(g.PlaceIds, game.PlaceId) or table.find(g.UniverseIds, game.GameId) then return g end
	end
	-- fallback: match on the place's title
	local ok, info = pcall(function() return MarketplaceService:GetProductInfo(game.PlaceId) end)
	if ok and info and info.Name then
		local title = info.Name:lower()
		for _, g in Games.List do
			if g.NameHint and title:find(g.NameHint, 1, true) then return g end
		end
	end
	return nil
end

return Games
