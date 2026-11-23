ZoraGoldTracker = ZoraGoldTracker or {}
local ZGT = ZoraGoldTracker
local UI = ZGT.UI

if not UI then
	return
end

local WIDTH = 520
local HEIGHT = 480
local ROW_H = 18
local VISIBLE = 20
local LIST_LEFT = 16
local LIST_TOP = -88
local LIST_W = WIDTH - 32 - 16
local WHEEL_STEP = 3

local frame
local rows = {}
local flat = {}
local offset = 0
local syncing = false

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

local function SavePosition()
	frame:SetUserPlaced(false)
	local ok, point, _, relPoint, x, y = pcall(frame.GetPoint, frame, 1)
	x = ZGT.AsNumber(x)
	y = ZGT.AsNumber(y)
	if not ok or not ZGT.PointValid(point) or not x or not y then
		return
	end
	local settings = ZGT.GetSettings()
	settings.salesPoint = point
	settings.salesRelPoint = ZGT.PointValid(relPoint) and relPoint or point
	settings.salesX = x
	settings.salesY = y
end

local function RestorePosition()
	frame:ClearAllPoints()
	frame:SetUserPlaced(false)
	local settings = ZGT.GetSettings()
	local point = settings.salesPoint
	local x = ZGT.AsNumber(settings.salesX)
	local y = ZGT.AsNumber(settings.salesY)
	if ZGT.PointValid(point) and x and y then
		frame:SetPoint(point, UIParent, settings.salesRelPoint or point, x, y)
		return
	end
	local ledger = _G.ZoraGoldTrackerDetail
	if ledger and ledger:IsShown() then
		frame:SetPoint("TOPLEFT", ledger, "TOPRIGHT", 8, 0)
	else
		frame:SetPoint("CENTER", UIParent, "CENTER", 0, 40)
	end
end

local function ShowSaleTip(row)
	local entry = row.entry
	if not entry then
		GameTooltip:Hide()
		return
	end
	GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
	GameTooltip:ClearLines()
	GameTooltip:AddLine(entry.item or "Auction sale", 1, 0.86, 0.4)
	GameTooltip:AddLine(ZGT.FormatMoney(entry.copper or 0), 1, 1, 1)
	if type(entry.stamp) == "number" then
		GameTooltip:AddLine(date("%b %d  %H:%M", entry.stamp), 0.7, 0.7, 0.7)
	end
	if entry.character then
		GameTooltip:AddLine(UI.ShortName(entry.character), 0.7, 0.7, 0.7)
	end
	GameTooltip:Show()
end

local function PaintRow(row, item)
	row.entry = nil
	if not item then
		row:Hide()
		return
	end
	row:Show()
	row.name:ClearAllPoints()
	if item.kind == "header" then
		row.bg:Show()
		row.name:SetPoint("LEFT", row, "LEFT", 4, 0)
		row.name:SetPoint("RIGHT", row.value, "LEFT", -8, 0)
		row.name:SetText(UI.DateLabel(item.dateKey))
		row.name:SetTextColor(1, 0.86, 0.4)
		local word = item.count == 1 and " sale" or " sales"
		row.value:SetText(item.count .. word .. "   " .. ZGT.FormatMoney(item.total))
		row.value:SetTextColor(ZGT.COLOR.text[1], ZGT.COLOR.text[2], ZGT.COLOR.text[3])
		return
	end
	local entry = item.entry
	row.bg:Hide()
	row.entry = entry
	row.name:SetPoint("LEFT", row, "LEFT", 16, 0)
	row.name:SetPoint("RIGHT", row.value, "LEFT", -8, 0)
	local who = ""
	if frame.scope == "account" and entry.character then
		who = "  ·  " .. UI.ShortName(entry.character)
	end
	row.name:SetText((entry.clock or "") .. "   " .. (entry.item or "Auction sale") .. who)
	row.name:SetTextColor(ZGT.COLOR.text[1], ZGT.COLOR.text[2], ZGT.COLOR.text[3])
	row.value:SetText(ZGT.FormatMoney(entry.copper or 0))
	row.value:SetTextColor(ZGT.COLOR.auctions[1], ZGT.COLOR.auctions[2], ZGT.COLOR.auctions[3])
end

local function MaxOffset()
	local over = #flat - VISIBLE
	return over > 0 and over or 0
end

local function Render()
	for index = 1, VISIBLE do
		PaintRow(rows[index], flat[offset + index])
	end
	if #flat == 0 then
		local row = rows[1]
		row:Show()
		row.bg:Hide()
		row.entry = nil
		row.name:ClearAllPoints()
		row.name:SetPoint("LEFT", row, "LEFT", 4, 0)
		row.name:SetPoint("RIGHT", row.value, "LEFT", -8, 0)
		row.name:SetText("No auction sales recorded.")
		row.name:SetTextColor(ZGT.COLOR.muted[1], ZGT.COLOR.muted[2], ZGT.COLOR.muted[3])
		row.value:SetText("")
	end
end

local function SyncSlider()
	local maxOffset = MaxOffset()
	syncing = true
	frame.slider:SetMinMaxValues(0, maxOffset)
	frame.slider:SetValue(offset)
	syncing = false
	if maxOffset > 0 then
		frame.slider:Show()
	else
		frame.slider:Hide()
	end
end

local function SetOffset(value)
	local maxOffset = MaxOffset()
	value = math.floor((value or 0) + 0.5)
	if value < 0 then
		value = 0
	elseif value > maxOffset then
		value = maxOffset
	end
	if value == offset then
		return
	end
	offset = value
	syncing = true
	frame.slider:SetValue(offset)
	syncing = false
	Render()
end

local function OnWheel(_, delta)
	SetOffset(offset - delta * WHEEL_STEP)
end

local function Rebuild()
	local scope = frame.scope or "account"
	local days = ZGT.GetAuctionDays(scope)
	flat = {}
	local sales, total = 0, 0
	for dayIndex = 1, #days do
		local day = days[dayIndex]
		flat[#flat + 1] = { kind = "header", dateKey = day.dateKey, count = #day.entries, total = day.total }
		for index = 1, #day.entries do
			flat[#flat + 1] = { kind = "sale", entry = day.entries[index] }
		end
		sales = sales + #day.entries
		total = total + day.total
	end
	UI.PaintScope(frame.accountButton, scope == "account")
	UI.PaintScope(frame.characterButton, scope == "character")
	local who
	if scope == "character" then
		local key = ZGT.GetCharacterKey()
		who = key and ("Character · " .. UI.ShortName(key)) or "Character"
	else
		who = "Account · all characters"
	end
	if sales == 0 then
		frame.summaryText:SetText("No sales")
	else
		local dayWord = #days == 1 and " day" or " days"
		local saleWord = sales == 1 and " sale" or " sales"
		frame.summaryText:SetText(sales .. saleWord .. " over " .. #days .. dayWord .. "    " .. ZGT.FormatMoney(total))
	end
	frame.scopeText:SetText(who)
	local maxOffset = MaxOffset()
	if offset > maxOffset then
		offset = maxOffset
	end
	SyncSlider()
	Render()
end

function ZGT.RefreshSales()
	if not frame or not frame:IsShown() or not ZGT.DB then
		return
	end
	Rebuild()
end

function ZGT.ToggleSales()
	if not frame then
		return
	end
	if frame:IsShown() then
		frame:Hide()
		return
	end
	frame.scope = UI.GetScope()
	offset = 0
	RestorePosition()
	frame:Show()
	RaiseSpecial("ZoraGoldTrackerSales")
	Rebuild()
end

local function Build()
	frame = CreateFrame("Frame", "ZoraGoldTrackerSales", UIParent, "BackdropTemplate")
	frame:SetSize(WIDTH, HEIGHT)
	frame:SetFrameStrata("DIALOG")
	frame:SetToplevel(true)
	frame:SetClampedToScreen(true)
	frame:SetMovable(true)
	frame:EnableMouseWheel(true)
	frame:SetScript("OnMouseWheel", OnWheel)
	frame:Hide()
	frame.scope = "account"
	ZGT.ApplyBackdrop(frame, 0.96)
	RaiseSpecial("ZoraGoldTrackerSales")

	local drag = CreateFrame("Frame", nil, frame)
	drag:SetPoint("TOPLEFT", 0, 0)
	drag:SetPoint("TOPRIGHT", -28, 0)
	drag:SetHeight(28)
	drag:EnableMouse(true)
	drag:RegisterForDrag("LeftButton")
	drag:SetScript("OnDragStart", function()
		frame:StartMoving()
	end)
	drag:SetScript("OnDragStop", function()
		frame:StopMovingOrSizing()
		SavePosition()
	end)

	local title = UI.Font(frame, "GameFontNormal", 14)
	title:SetPoint("TOPLEFT", 14, -8)
	title:SetText("Auction sales")

	local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", 2, 2)

	frame.accountButton = UI.FlatButton(frame, "Account", 84)
	frame.accountButton:SetPoint("TOPLEFT", 14, -34)
	frame.accountButton:SetScript("OnClick", function()
		frame.scope = "account"
		offset = 0
		Rebuild()
	end)
	frame.characterButton = UI.FlatButton(frame, "Character", 92)
	frame.characterButton:SetPoint("LEFT", frame.accountButton, "RIGHT", 6, 0)
	frame.characterButton:SetScript("OnClick", function()
		frame.scope = "character"
		offset = 0
		Rebuild()
	end)

	frame.scopeText = UI.Font(frame, "GameFontHighlightSmall", nil, ZGT.COLOR.muted[1], ZGT.COLOR.muted[2], ZGT.COLOR.muted[3])
	frame.scopeText:SetPoint("TOPLEFT", 16, -64)
	frame.summaryText = UI.Font(frame, "GameFontNormal")
	frame.summaryText:SetPoint("TOPRIGHT", -16, -62)
	frame.summaryText:SetJustifyH("RIGHT")

	for index = 1, VISIBLE do
		local row = CreateFrame("Frame", nil, frame)
		row:SetSize(LIST_W, ROW_H)
		row:SetPoint("TOPLEFT", LIST_LEFT, LIST_TOP - (index - 1) * ROW_H)
		row:EnableMouse(true)
		row:EnableMouseWheel(true)
		row:SetScript("OnMouseWheel", OnWheel)
		row.bg = row:CreateTexture(nil, "BACKGROUND")
		row.bg:SetAllPoints()
		ZGT.Paint(row.bg, { 0.78, 0.62, 0.22 }, 0.16)
		row.bg:Hide()
		row.value = UI.Font(row, "GameFontHighlightSmall")
		row.value:SetPoint("RIGHT", -4, 0)
		row.value:SetJustifyH("RIGHT")
		row.name = UI.Font(row, "GameFontHighlightSmall")
		row.name:SetPoint("LEFT", 4, 0)
		row.name:SetPoint("RIGHT", row.value, "LEFT", -8, 0)
		row:SetScript("OnEnter", ShowSaleTip)
		row:SetScript("OnLeave", function()
			GameTooltip:Hide()
		end)
		rows[index] = row
	end

	local slider = CreateFrame("Slider", nil, frame)
	slider:SetOrientation("VERTICAL")
	slider:SetPoint("TOPRIGHT", -14, LIST_TOP)
	slider:SetPoint("BOTTOMRIGHT", -14, 36)
	slider:SetWidth(8)
	slider:SetMinMaxValues(0, 0)
	slider:SetValueStep(1)
	if slider.SetObeyStepOnDrag then
		slider:SetObeyStepOnDrag(true)
	end
	slider:SetThumbTexture("Interface\\Buttons\\WHITE8X8")
	local thumb = slider:GetThumbTexture()
	if thumb then
		thumb:SetSize(8, 32)
		thumb:SetVertexColor(0.78, 0.62, 0.22, 0.9)
	end
	local track = slider:CreateTexture(nil, "BACKGROUND")
	track:SetAllPoints()
	track:SetColorTexture(1, 1, 1, 0.06)
	slider:SetScript("OnValueChanged", function(_, value)
		if syncing then
			return
		end
		SetOffset(value)
	end)
	slider:Hide()
	frame.slider = slider

	local note = UI.Font(frame, "GameFontHighlightSmall", 10, ZGT.COLOR.muted[1], ZGT.COLOR.muted[2], ZGT.COLOR.muted[3])
	note:SetPoint("BOTTOMLEFT", 16, 14)
	note:SetText("Last " .. ZGT.RetentionDays() .. " days  ·  up to " .. ZGT.AuctionLogCap() .. " sales per character per day are kept")

	frame:SetScript("OnShow", function()
		RaiseSpecial("ZoraGoldTrackerSales")
	end)
end

Build()
ZGT.AddListener(ZGT.RefreshSales)
