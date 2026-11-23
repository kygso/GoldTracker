ZoraGoldTracker = ZoraGoldTracker or {}
local ZGT = ZoraGoldTracker

local SPARK_DAYS = 7
local SPARK_W, SPARK_H = 76, 34
local TICKER_W, TICKER_H = 300, 52
local MIN_SCALE, MAX_SCALE, SCALE_STEP = 0.5, 2, 0.1

local ticker, menu, catcher, rateText, sessionText, arrow, sparkBars

local function Trim(text)
	if type(text) ~= "string" then
		return ""
	end
	if type(strtrim) == "function" then
		return strtrim(text)
	end
	return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function Say(message)
	print("|cffd9b333Zora Gold|r " .. message)
end

local reported = {}
local function ReportOnce(key, err)
	if reported[key] then
		return
	end
	reported[key] = true
	Say("sparkline error (" .. key .. "): " .. tostring(err))
end

local function RaiseSpecial(name)
	if type(UISpecialFrames) ~= "table" then
		return
	end
	for index = #UISpecialFrames, 1, -1 do
		if UISpecialFrames[index] == name then
			table.remove(UISpecialFrames, index)
		end
	end
	UISpecialFrames[#UISpecialFrames + 1] = name
end

local function SavePosition(frame, prefix)
	frame:SetUserPlaced(false)
	local ok, point, _, relPoint, x, y = pcall(frame.GetPoint, frame, 1)
	x = ZGT.AsNumber(x)
	y = ZGT.AsNumber(y)
	if not ok or not ZGT.PointValid(point) or not x or not y then
		return
	end
	local settings = ZGT.GetSettings()
	settings[prefix .. "Point"] = point
	settings[prefix .. "RelPoint"] = ZGT.PointValid(relPoint) and relPoint or point
	settings[prefix .. "X"] = x
	settings[prefix .. "Y"] = y
end

local function RestorePosition(frame, prefix, point, x, y)
	frame:ClearAllPoints()
	frame:SetUserPlaced(false)
	local settings = ZGT.GetSettings()
	local savedPoint = settings[prefix .. "Point"]
	local savedX = ZGT.AsNumber(settings[prefix .. "X"])
	local savedY = ZGT.AsNumber(settings[prefix .. "Y"])
	if ZGT.PointValid(savedPoint) and savedX and savedY then
		frame:SetPoint(savedPoint, UIParent, settings[prefix .. "RelPoint"] or savedPoint, savedX, savedY)
	else
		frame:SetPoint(point, UIParent, point, x, y)
	end
end

local function PlaceBar(bar, height, color, alpha)
	bar:SetColorTexture(color[1], color[2], color[3], alpha)
	bar:SetHeight(height)
	bar:Show()
end

local function UpdateSpark(scope)
	if not sparkBars then
		return
	end
	local today = ZGT.TodayKey()
	local values = {}
	for index = SPARK_DAYS - 1, 0, -1 do
		local view = ZGT.GetView(ZGT.DateOffset(today, -index), scope)
		values[#values + 1] = view.net or 0
	end
	local minValue, maxValue = values[1], values[1]
	for index = 2, #values do
		if values[index] < minValue then
			minValue = values[index]
		end
		if values[index] > maxValue then
			maxValue = values[index]
		end
	end
	if minValue == maxValue then
		minValue = minValue - 1
		maxValue = maxValue + 1
	end
	local largest = 0
	for index = 1, #values do
		if math.abs(values[index]) > largest then
			largest = math.abs(values[index])
		end
	end
	if largest == 0 then
		largest = 1
	end
	for index = 1, #values do
		local value = values[index]
		local bar = sparkBars[index]
		local height = math.max(2, math.abs(value) / largest * (SPARK_H - 2))
		if value > 0 then
			PlaceBar(bar, height, ZGT.COLOR.up, 0.95)
		elseif value < 0 then
			PlaceBar(bar, height, ZGT.COLOR.down, 0.95)
		else
			PlaceBar(bar, 2, ZGT.COLOR.flat, 0.35)
		end
	end
end

local function ClampScale(scale)
	if type(scale) ~= "number" then
		return 1
	end
	if scale < MIN_SCALE then
		return MIN_SCALE
	end
	if scale > MAX_SCALE then
		return MAX_SCALE
	end
	return math.floor(scale * 10 + 0.5) / 10
end

local function ScaleText(scale)
	return string.format("%d%%", math.floor(scale * 100 + 0.5))
end

local function ApplyScale()
	if not ticker then
		return 1
	end
	local settings = ZGT.GetSettings()
	local scale = ClampScale(settings.tickerScale)
	settings.tickerScale = scale
	ticker:SetScale(scale)
	return scale
end

local RefreshMenu

local function StepScale(delta)
	local settings = ZGT.GetSettings()
	settings.tickerScale = ClampScale((settings.tickerScale or 1) + delta)
	ApplyScale()
	RefreshMenu()
end

function RefreshMenu()
	if not menu or not menu.lockLabel then
		return
	end
	local locked = ZGT.GetSettings().locked
	menu.lockLabel:SetText(locked and "Unlock" or "Lock")
	if menu.scaleLabel then
		menu.scaleLabel:SetText(ScaleText(ClampScale(ZGT.GetSettings().tickerScale)))
	end
end

local function RefreshTicker()
	if not ticker or not ZGT.DB or not ticker:IsShown() then
		return
	end
	local comparison = ZGT.GetComparison(ZGT.TodayKey(), "account")
	local color = ZGT.COLOR[comparison.direction] or ZGT.COLOR.flat
	local hex = ZGT.ColorHex(color)
	local headline
	if comparison.todayRate then
		headline = ZGT.FormatRate(comparison.todayRate)
	else
		headline = ZGT.FormatCompact(comparison.today.net) .. "   —"
	end
	local percent = ZGT.FormatPercent(comparison.percent)
	if percent then
		headline = headline .. "   " .. percent
	end
	rateText:SetText("|cff" .. hex .. headline .. "|r")
	if comparison.direction == "up" then
		arrow:SetTexture("Interface\\Buttons\\Arrow-Up-Up")
		arrow:SetVertexColor(color[1], color[2], color[3])
		arrow:Show()
	elseif comparison.direction == "down" then
		arrow:SetTexture("Interface\\Buttons\\Arrow-Down-Up")
		arrow:SetVertexColor(color[1], color[2], color[3])
		arrow:Show()
	else
		arrow:Hide()
	end
	rateText:ClearAllPoints()
	rateText:SetWidth(176)
	if arrow:IsShown() then
		rateText:SetPoint("LEFT", arrow, "RIGHT", 4, 0)
	else
		rateText:SetPoint("TOPLEFT", ticker, "TOPLEFT", 10, -6)
	end

	local sessionNet, sessionPlayed = ZGT.GetSession()
	local sessionRate = ZGT.GoldPerHour(sessionNet, sessionPlayed)
	sessionText:SetText("session  " .. ZGT.FormatCompact(sessionNet) .. "    " .. (sessionRate and ZGT.FormatRate(sessionRate) or "—"))
	if ticker.SetBackdropBorderColor then
		ticker:SetBackdropBorderColor(color[1], color[2], color[3], 0.95)
	end
	local ok, err = pcall(UpdateSpark, "account")
	if not ok then
		ReportOnce("spark", err)
	end
	RefreshMenu()
end

local function ShowTicker()
	local settings = ZGT.GetSettings()
	settings.tickerHidden = false
	ApplyScale()
	RestorePosition(ticker, "ticker", "TOP", 0, -80)
	ticker:Show()
	RefreshTicker()
end

local function HideTicker()
	ZGT.GetSettings().tickerHidden = true
	menu:Hide()
	ticker:Hide()
	Say("Ticker hidden. /zgt to show it.")
end

local function ToggleLock()
	local settings = ZGT.GetSettings()
	settings.locked = not settings.locked
	menu:Hide()
	RefreshTicker()
	Say(settings.locked and "Ticker locked." or "Ticker unlocked.")
end

local function ResetTicker()
	local settings = ZGT.GetSettings()
	settings.tickerPoint = nil
	settings.tickerRelPoint = nil
	settings.tickerX = nil
	settings.tickerY = nil
	menu:Hide()
	RestorePosition(ticker, "ticker", "TOP", 0, -80)
	Say("Ticker position reset.")
end

local function MenuButton(text, y, onClick)
	local button = CreateFrame("Button", nil, menu)
	button:SetSize(132, 22)
	button:SetPoint("TOP", 0, y)
	local background = button:CreateTexture(nil, "BACKGROUND")
	background:SetAllPoints()
	ZGT.Paint(background, { 1, 0.82, 0 }, 0.18)
	background:Hide()
	local label = button:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	label:SetPoint("LEFT", 8, 0)
	label:SetText(text)
	button:SetScript("OnEnter", function()
		background:Show()
	end)
	button:SetScript("OnLeave", function()
		background:Hide()
	end)
	button:SetScript("OnClick", onClick)
	return label
end

local function BuildMenu()
	menu = CreateFrame("Frame", "ZoraGoldTrackerTickerMenu", UIParent, "BackdropTemplate")
	menu:SetSize(148, 104)
	menu:SetFrameStrata("FULLSCREEN_DIALOG")
	menu:SetFrameLevel(20)
	menu:SetClampedToScreen(true)
	menu:Hide()
	ZGT.ApplyBackdrop(menu, 0.96)
	menu.lockLabel = MenuButton("Lock", -6, ToggleLock)
	MenuButton("Reset position", -28, ResetTicker)
	MenuButton("Hide", -50, HideTicker)

	local scaleRow = CreateFrame("Frame", nil, menu)
	scaleRow:SetSize(132, 22)
	scaleRow:SetPoint("TOP", 0, -72)
	local smaller = CreateFrame("Button", nil, scaleRow)
	smaller:SetSize(22, 22)
	smaller:SetPoint("LEFT", 0, 0)
	local smallerLabel = smaller:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	smallerLabel:SetPoint("CENTER")
	smallerLabel:SetText("-")
	smaller:SetScript("OnClick", function()
		StepScale(-SCALE_STEP)
	end)
	local larger = CreateFrame("Button", nil, scaleRow)
	larger:SetSize(22, 22)
	larger:SetPoint("RIGHT", 0, 0)
	local largerLabel = larger:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	largerLabel:SetPoint("CENTER")
	largerLabel:SetText("+")
	larger:SetScript("OnClick", function()
		StepScale(SCALE_STEP)
	end)
	menu.scaleLabel = scaleRow:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	menu.scaleLabel:SetPoint("CENTER")
	menu.scaleLabel:SetText("100%")
	local function Highlight(button, on)
		button:SetAlpha(on and 1 or 0.75)
	end
	smaller:SetScript("OnEnter", function(self) Highlight(self, true) end)
	smaller:SetScript("OnLeave", function(self) Highlight(self, false) end)
	larger:SetScript("OnEnter", function(self) Highlight(self, true) end)
	larger:SetScript("OnLeave", function(self) Highlight(self, false) end)
	smaller:SetAlpha(0.75)
	larger:SetAlpha(0.75)
	menu:SetScript("OnShow", function()
		RefreshMenu()
		RaiseSpecial("ZoraGoldTrackerTickerMenu")
		catcher:Show()
	end)
	menu:SetScript("OnHide", function()
		catcher:Hide()
	end)

	catcher = CreateFrame("Frame", nil, UIParent)
	catcher:SetAllPoints()
	catcher:EnableMouse(true)
	catcher:SetFrameStrata("FULLSCREEN_DIALOG")
	catcher:SetFrameLevel(1)
	catcher:Hide()
	catcher:SetScript("OnMouseDown", function()
		menu:Hide()
	end)
end

local function ShowMenu()
	RefreshMenu()
	menu:ClearAllPoints()
	menu:SetPoint("TOPLEFT", ticker, "BOTTOMLEFT", 0, -2)
	menu:Show()
end

local function BuildTicker()
	ticker = CreateFrame("Frame", "ZoraGoldTrackerTicker", UIParent, "BackdropTemplate")
	ticker:SetSize(TICKER_W, TICKER_H)
	ticker:SetFrameStrata("HIGH")
	ticker:SetClampedToScreen(true)
	ticker:SetMovable(true)
	ticker:EnableMouse(true)
	ticker:RegisterForDrag("LeftButton")
	ticker:Hide()
	ZGT.ApplyBackdrop(ticker, 0.9)

	arrow = ticker:CreateTexture(nil, "OVERLAY")
	arrow:SetSize(14, 14)
	arrow:SetPoint("TOPLEFT", 8, -8)
	arrow:SetTexture("Interface\\Buttons\\Arrow-Up-Up")

	local spark = CreateFrame("Frame", nil, ticker)
	spark:SetSize(SPARK_W, SPARK_H)
	spark:SetPoint("RIGHT", -8, 0)
	sparkBars = {}
	local slotWidth = SPARK_W / SPARK_DAYS
	for index = 1, SPARK_DAYS do
		local bar = spark:CreateTexture(nil, "OVERLAY")
		bar:SetWidth(slotWidth - 3)
		bar:SetPoint("BOTTOMLEFT", spark, "BOTTOMLEFT", (index - 1) * slotWidth + 1, 0)
		bar:Hide()
		sparkBars[index] = bar
	end

	rateText = ticker:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	rateText:SetJustifyH("LEFT")
	rateText:SetWordWrap(false)
	if rateText.SetMaxLines then
		rateText:SetMaxLines(1)
	end
	rateText:SetWidth(176)
	rateText:SetPoint("LEFT", arrow, "RIGHT", 4, 0)

	sessionText = ticker:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	sessionText:SetJustifyH("LEFT")
	sessionText:SetWordWrap(false)
	if sessionText.SetMaxLines then
		sessionText:SetMaxLines(1)
	end
	sessionText:SetTextColor(ZGT.COLOR.muted[1], ZGT.COLOR.muted[2], ZGT.COLOR.muted[3])
	sessionText:SetWidth(190)
	sessionText:SetPoint("BOTTOMLEFT", 10, 6)

	ticker:SetScript("OnDragStart", function(self)
		if ZGT.GetSettings().locked then
			return
		end
		self.dragged = true
		menu:Hide()
		self:StartMoving()
	end)
	ticker:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		SavePosition(self, "ticker")
	end)
	ticker:SetScript("OnMouseUp", function(self, button)
		if button == "LeftButton" then
			if self.dragged then
				self.dragged = nil
				return
			end
			menu:Hide()
			if ZGT.ToggleDetail then
				ZGT.ToggleDetail()
			end
		elseif button == "RightButton" then
			if menu:IsShown() then
				menu:Hide()
			else
				ShowMenu()
			end
		end
	end)
	ticker:EnableMouseWheel(true)
	ticker:SetScript("OnMouseWheel", function(_, delta)
		if not delta or delta == 0 then
			return
		end
		StepScale(delta > 0 and SCALE_STEP or -SCALE_STEP)
	end)
end

local function Slash(message)
	if not ZGT.DB then
		return
	end
	local command = Trim(message):lower()
	if command == "show" then
		ShowTicker()
	elseif command == "hide" then
		HideTicker()
	elseif command == "lock" then
		ToggleLock()
	elseif command == "reset" then
		ResetTicker()
	elseif command == "scale" then
		Say("Ticker scale is " .. ScaleText(ApplyScale()) .. ". Wheel on the ticker, or /zgt scale 50-200.")
	elseif command:match("^scale%s+") then
		local value = command:match("^scale%s+(%S+)")
		if value == "up" then
			StepScale(SCALE_STEP)
			Say("Ticker scale is " .. ScaleText(ClampScale(ZGT.GetSettings().tickerScale)) .. ".")
		elseif value == "down" then
			StepScale(-SCALE_STEP)
			Say("Ticker scale is " .. ScaleText(ClampScale(ZGT.GetSettings().tickerScale)) .. ".")
		else
			local number = tonumber(value)
			if not number then
				Say("Usage: /zgt scale 50-200.")
			else
				if number > 3 then
					number = number / 100
				end
				ZGT.GetSettings().tickerScale = number
				Say("Ticker scale is " .. ScaleText(ApplyScale()) .. ".")
				RefreshMenu()
			end
		end
	elseif command == "help" then
		Say("/zgt show, hide, lock, reset, scale. /zgt toggles the ledger.")
	else
		ShowTicker()
		if ZGT.ToggleDetail then
			ZGT.ToggleDetail()
		end
	end
end

BuildTicker()
BuildMenu()

SLASH_ZORAGOLD1 = "/zgt"
SLASH_ZORAGOLD2 = "/zoragold"
SlashCmdList.ZORAGOLD = Slash

local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:SetScript("OnEvent", function(_, _, name)
	if name ~= "ZoraGoldTracker" then
		return
	end
	loader:UnregisterEvent("ADDON_LOADED")
	if ZGT.GetSettings().tickerHidden then
		ApplyScale()
		ticker:Hide()
	else
		ShowTicker()
	end
	ZGT.AddListener(RefreshTicker)
end)
