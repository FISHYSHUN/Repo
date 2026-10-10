-- modules/Comfort.lua
-- Quality-of-life settings: tab labels (icons / text / both), spacing, notification placement.
local import = ...

local TextService = game:GetService("TextService")

local T = import("Theme")
local Theme, State = T.Theme, T.State

local MODES = { "Icons", "Text", "Both" }
local CORNERS = { "Bottom Right", "Bottom Left", "Top Right", "Top Left" }

return function(GuiUI)

	function GuiUI:GetTabDisplayModes() return table.clone(MODES) end
	function GuiUI:GetToastCorners() return table.clone(CORNERS) end

	-- text / size of every sidebar tab button for the current display mode
	function GuiUI:_refreshTabLabels()
		local hz = State.Skin.Horizontal == true
		local S = Theme.Size
		local mode = self.TabDisplay
		local both = mode == "Both"
		for _, tab in self.Tabs do
			if not tab.IsBottom then
				local btn = tab.Button
				local face = btn.Face
				local img = face:FindFirstChildOfClass("ImageLabel")

				local text
				if tab.IsImage then
					text = mode == "Icons" and "" or tab.Name
				else
					local glyph = tab.Icon or tab.Name:sub(1, 1)
					if mode == "Icons" then text = glyph
					elseif mode == "Text" then text = tab.Name
					else text = glyph .. "  " .. tab.Name end
				end

				local imageBeside = both and img ~= nil
				if img then
					img.Visible = mode ~= "Text"
					img.AnchorPoint = both and Vector2.new(0, 0.5) or Vector2.new(0.5, 0.5)
					img.Position = both and UDim2.new(0, 10, 0.5, 0) or UDim2.fromScale(0.5, 0.5)
				end
				btn.Pad.PaddingLeft = imageBeside and UDim.new(0, 40) or UDim.new(0, 4)
				face.TextXAlignment = imageBeside and Enum.TextXAlignment.Left or Enum.TextXAlignment.Center
				face.TextSize = mode == "Icons" and 24 or Theme.FontSize.Small
				btn.SetText(text)

				if hz then
					local w = S.TabIcon
					if mode ~= "Icons" then
						local bounds = TextService:GetTextSize(text, face.TextSize, Theme.Font, Vector2.new(1000, 100))
						w = math.max(S.TabIcon, math.ceil(bounds.X) + (imageBeside and 52 or 24))
					end
					btn.Holder.Size = UDim2.new(0, w, 1, 0)
				else
					btn.Holder.Size = UDim2.new(1, 0, 0, S.Tab)
				end
			end
		end
	end

	function GuiUI:SetTabDisplay(mode)
		if not table.find(MODES, mode) then return end
		self.TabDisplay = mode
		self:_refreshTabLabels()
		local tab = self.Tabs[self.CurrentTab]
		if tab and not tab.IsBottom then self:_revealTab(tab) end
	end

	function GuiUI:SetTabSpacing(px)
		self.TabGap = math.clamp(math.round(px), 0, 24)
		self.TabListLayout.Padding = UDim.new(0, self.TabGap)
	end

	function GuiUI:SetControlSpacing(px)
		self.ControlGap = math.clamp(math.round(px), 0, 20)
		for i = #self._spacers, 1, -1 do
			local s = self._spacers[i]
			if s[1].Parent == nil then
				table.remove(self._spacers, i)
			else
				s[1].Padding = UDim.new(0, self.ControlGap + s[2])
			end
		end
	end

	function GuiUI:SetNotifications(enabled) self.Notifications = enabled end
	function GuiUI:SetToastTime(multiplier) self.ToastScale = math.clamp(multiplier, 0.5, 3) end

	function GuiUI:SetToastCorner(name)
		if not table.find(CORNERS, name) then return end
		local right = name:find("Right") ~= nil
		local bottom = name:find("Bottom") ~= nil
		local area = self.ToastArea
		area.AnchorPoint = Vector2.new(right and 1 or 0, bottom and 1 or 0)
		area.Position = UDim2.new(right and 1 or 0, right and -16 or 16, bottom and 1 or 0, bottom and -16 or 16)
		local layout = area:FindFirstChildOfClass("UIListLayout")
		if layout then
			layout.VerticalAlignment = bottom and Enum.VerticalAlignment.Bottom or Enum.VerticalAlignment.Top
		end
		self.ToastDir = right and 320 or -320
	end

	-- the font changes text widths, so re-measure the tab buttons
	local baseSetFont = GuiUI.SetFont
	function GuiUI:SetFont(name)
		baseSetFont(self, name)
		self:_refreshTabLabels()
	end

end
