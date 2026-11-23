ZoraGoldTracker = ZoraGoldTracker or {}
local ZGT = ZoraGoldTracker

local CHART_WINDOW = 14
local RANGE_PRESET = 7
local PLOT_W, PLOT_H = 488, 70
local WIDTH = 520
local BREAKDOWN = {
	{ key = "loot", label = "Loot", color = "loot" },
	{ key = "auctions", label = "Auctions", color = "auctions" },
	{ key = "vendor", label = "Vendored", color = "vendor" },
	{ key = "quests", label = "Quests", color = "quests" },
	{ key = "other", label = "Other", color = "other" },
	{ key = "auctionBuy", label = "Auction buys", color = "auctionBuy", spend = true },
	{ key = "deposit", label = "Deposits", color = "deposit", spend = true },
	{ key = "flight", label = "Flight paths", color = "flight", spend = true },
	{ key = "repairs", label = "Repairs", color = "repairs", spend = true },
	{ key = "vendorBuy", label = "Vendor buys", color = "vendorBuy", spend = true },
	{ key = "training", label = "Training", color = "training", spend = true },
	{ key = "spent", label = "Other spent", color = "spent", spend = true },
}
local INCOME_ROWS = {}
local SPEND_ROWS = {}
for index = 1, #BREAKDOWN do
	if BREAKDOWN[index].spend then
		SPEND_ROWS[#SPEND_ROWS + 1] = BREAKDOWN[index]
	else
		INCOME_ROWS[#INCOME_ROWS + 1] = BREAKDOWN[index]
	end
end

local detail
local sourceRows = {}
local characterRows = {}
local auctionRows = {}
local columns = {}
local netMarkers = {}

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

local function SavePosition(frame)
	frame:SetUserPlaced(false)
	local ok, point, _, relPoint, x, y = pcall(frame.GetPoint, frame, 1)
	x = ZGT.AsNumber(x)
	y = ZGT.AsNumber(y)
	if not ok or not ZGT.PointValid(point) or not x or not y then
		return
	end
	local settings = ZGT.GetSettings()
	settings.detailPoint = point
	settings.detailRelPoint = ZGT.PointValid(relPoint) and relPoint or point
	settings.detailX = x
	settings.detailY = y
end

local function RestorePosition(frame)
	frame:ClearAllPoints()
	frame:SetUserPlaced(false)
	local settings = ZGT.GetSettings()
	local point = settings.detailPoint
	local x = ZGT.AsNumber(settings.detailX)
	local y = ZGT.AsNumber(settings.detailY)
	if ZGT.PointValid(point) and x and y then
		frame:SetPoint(point, UIParent, settings.detailRelPoint or point, x, y)
	else
		frame:SetPoint("CENTER", UIParent, "CENTER", 0, 40)
	end
end

local function RealmText(reader)
	if type(reader) ~= "function" then
		return nil
	end
	local ok, value = pcall(reader)
	if not ok or not ZGT.IsReadable(value) or type(value) ~= "string" or value == "" then
		return nil
	end
	return value
end

local function ShortName(key)
	local name, suffix = tostring(key or ""):match("^(.-)%-(.+)$")
	if not name or not suffix or suffix == "" then
		return tostring(key or "")
	end
	local here = RealmText(GetRealmName)
	if here and suffix == here then
		return name
	end
	local normalized = RealmText(GetNormalizedRealmName)
	if normalized and suffix == normalized then
		return name
	end
	if suffix ~= "Unknown" and not suffix:find("%s") then
		return name .. " " .. suffix
	end
	return tostring(key)
end

local function DateLabel(dateKey)
	local today = ZGT.TodayKey()
	local year, month, day = tostring(dateKey):match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
	local stamp
	if year then
		stamp = time({ year = tonumber(year), month = tonumber(month), day = tonumber(day), hour = 12 })
	end
	local pretty = stamp and date("%a %b %d", stamp) or tostring(dateKey)
	if dateKey == today then
		return "Today · " .. pretty
	end
	if dateKey == ZGT.DateOffset(today, -1) then
		return "Yesterday · " .. pretty
	end
	return pretty
end

local function ShortDate(dateKey)
	local today = ZGT.TodayKey()
	if dateKey == today then
		return "Today"
	end
	if dateKey == ZGT.DateOffset(today, -1) then
		return "Yesterday"
	end
	local year, month, day = tostring(dateKey):match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
	if not year then
		return tostring(dateKey)
	end
	local stamp = time({ year = tonumber(year), month = tonumber(month), day = tonumber(day), hour = 12 })
	if not stamp then
		return tostring(dateKey)
	end
	if year ~= today:sub(1, 4) then
		return date("%b %d %Y", stamp)
	end
	return date("%b %d", stamp)
end

local function PeriodLabel(mode, startKey, endKey)
	if mode == "range" and detail.rangeAnchor and startKey == endKey then
		return ShortDate(startKey) .. "  ·  click the other day"
	end
	if mode == "all" then
		if startKey == endKey then
			return "All time  ·  " .. ShortDate(startKey)
		end
		return "All time  ·  " .. ShortDate(startKey) .. " to " .. ShortDate(endKey)
	end
	if startKey == endKey then
		return DateLabel(startKey)
	end
	return ShortDate(startKey) .. " to " .. ShortDate(endKey) .. "  ·  " .. ZGT.SpanDays(startKey, endKey) .. " days"
end

local function ButtonTip(button, text)
	button:SetScript("OnEnter", function()
		GameTooltip:SetOwner(button, "ANCHOR_TOP")
		GameTooltip:ClearLines()
		GameTooltip:AddLine(text, 1, 0.92, 0.7, true)
		GameTooltip:Show()
	end)
	button:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)
end

local function Font(parent, template, size, r, g, b)
	local text = parent:CreateFontString(nil, "OVERLAY", template or "GameFontHighlightSmall")
	text:SetJustifyH("LEFT")
	if size then
		local font, _, flags = text:GetFont()
		if font then
			text:SetFont(font, size, flags)
		end
	end
	if r then
		text:SetTextColor(r, g, b)
	end
	if text.SetMaxLines then
		text:SetMaxLines(1)
	end
	text:SetWordWrap(false)
	return text
end

local function FlatButton(parent, text, width)
	local button = CreateFrame("Button", nil, parent, "BackdropTemplate")
	button:SetSize(width, 20)
	if button.SetBackdrop then
		pcall(button.SetBackdrop, button, {
			bgFile = "Interface\\Buttons\\WHITE8X8",
			edgeFile = "Interface\\Buttons\\WHITE8X8",
			edgeSize = 1,
		})
	end
	button.label = Font(button, "GameFontHighlightSmall")
	button.label:SetPoint("CENTER")
	button.label:SetText(text)
	return button
end

local function PaintScope(button, selected)
	if not button.SetBackdropColor then
		return
	end
	local function paint()
		if selected then
			button:SetBackdropColor(0.78, 0.62, 0.22, 0.40)
			button:SetBackdropBorderColor(0.95, 0.78, 0.32, 1)
			button.label:SetTextColor(1, 0.92, 0.7)
		else
			button:SetBackdropColor(1, 1, 1, 0.05)
			button:SetBackdropBorderColor(1, 1, 1, 0.16)
			button.label:SetTextColor(0.82, 0.82, 0.86)
		end
	end
	pcall(paint)
end

local function AddTipLine(label, copper, color)
	GameTooltip:AddDoubleLine(label, ZGT.FormatMoney(copper), color[1], color[2], color[3], 1, 1, 1)
end

local function SignedAmount(spec, amount)
	amount = amount or 0
	if spec.spend then
		return -amount
	end
	return amount
end

-- Training per skill line, biggest first. Whatever the split does not cover
-- (spending recorded before the split existed) shows as "Other".
local function TrainingEntries(snap)
	local totals, entries, sum = {}, {}, 0
	local by = type(snap.trainingBy) == "table" and snap.trainingBy or {}
	for skill, amount in pairs(by) do
		if type(skill) == "string" and type(amount) == "number" and amount > 0 then
			local name = ZGT.TrainingGroup(skill)
			totals[name] = (totals[name] or 0) + amount
			sum = sum + amount
		end
	end
	for name, amount in pairs(totals) do
		entries[#entries + 1] = { name = name, amount = amount }
	end
	table.sort(entries, function(a, b)
		if a.amount == b.amount then
			return a.name < b.name
		end
		return a.amount > b.amount
	end)
	local rest = (snap.training or 0) - sum
	if rest > 0 then
		entries[#entries + 1] = { name = "Other", amount = rest }
	end
	return entries
end

local function AddTrainingLines(entries)
	local muted = ZGT.COLOR.muted
	for index = 1, #entries do
		GameTooltip:AddDoubleLine("    " .. entries[index].name, ZGT.FormatMoney(-entries[index].amount), muted[1], muted[2], muted[3], 1, 1, 1)
	end
end

local function AddBreakdown(snap)
	for index = 1, #BREAKDOWN do
		local spec = BREAKDOWN[index]
		AddTipLine(spec.label, SignedAmount(spec, snap[spec.key]), ZGT.COLOR[spec.color])
		if spec.key == "training" then
			local entries = TrainingEntries(snap)
			-- A lone "Other" is just the total again, so skip it here.
			if not (#entries == 1 and entries[1].name == "Other") then
				AddTrainingLines(entries)
			end
		end
	end
end

local function ShowTrainingTip(owner)
	local snap = detail and detail.view
	if not snap then
		GameTooltip:Hide()
		return
	end
	local entries = TrainingEntries(snap)
	GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
	GameTooltip:ClearLines()
	GameTooltip:AddLine("Training", 1, 0.86, 0.4)
	if #entries == 0 then
		GameTooltip:AddLine("No training in this period.", 0.7, 0.7, 0.7)
	else
		AddTrainingLines(entries)
	end
	GameTooltip:Show()
end

local function ShowDayTip(column)
	local snap = column.snapshot
	if not snap then
		return
	end
	GameTooltip:SetOwner(column, "ANCHOR_TOP")
	GameTooltip:ClearLines()
	GameTooltip:AddLine(DateLabel(snap.dateKey), 1, 0.86, 0.4)
	AddBreakdown(snap)
	GameTooltip:AddLine(" ")
	AddTipLine("Net", snap.net, ZGT.COLOR.text)
	local rate = ZGT.GoldPerHour(snap.net, snap.played)
	GameTooltip:AddDoubleLine("Per hour", rate and ZGT.FormatRate(rate) or "—", 0.8, 0.8, 0.8, 1, 1, 1)
	GameTooltip:AddDoubleLine("Played", ZGT.FormatPlayed(snap.played), 0.8, 0.8, 0.8, 1, 1, 1)
	GameTooltip:Show()
end

local function ShowCharacterTip(row)
	local snap = row.snapshot
	if not snap then
		GameTooltip:Hide()
		return
	end
	GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
	GameTooltip:ClearLines()
	GameTooltip:AddLine(ShortName(snap.key), 1, 0.86, 0.4)
	AddBreakdown(snap)
	GameTooltip:AddLine(" ")
	AddTipLine("Net", snap.net, ZGT.COLOR.text)
	GameTooltip:AddDoubleLine("Played", ZGT.FormatPlayed(snap.played), 0.8, 0.8, 0.8, 1, 1, 1)
	GameTooltip:Show()
end

local function CurrentPeriod()
	local today = ZGT.TodayKey()
	local oldest = ZGT.RetentionStart()
	if detail.mode == "all" then
		local startKey = ZGT.OldestStoredDate()
		if startKey < oldest or startKey > today then
			startKey = today < oldest and today or oldest
		end
		return startKey, today
	end
	if detail.mode == "range" then
		local startKey = detail.rangeStart or today
		local endKey = detail.rangeEnd or startKey
		if endKey > today then
			endKey = today
		end
		if endKey < oldest then
			endKey = oldest
		end
		if startKey < oldest then
			startKey = oldest
		end
		if startKey > endKey then
			startKey = endKey
		end
		detail.rangeStart = startKey
		detail.rangeEnd = endKey
		return startKey, endKey
	end
	if detail.followToday or not detail.selectedDate then
		detail.selectedDate = today
		detail.followToday = true
	end
	local dateKey = detail.selectedDate
	if type(dateKey) ~= "string" or dateKey > today then
		dateKey = today
	end
	if dateKey < oldest then
		dateKey = oldest
	end
	detail.selectedDate = dateKey
	return dateKey, dateKey
end

local function SelectDate(dateKey)
	detail.mode = "day"
	detail.rangeAnchor = nil
	detail.selectedDate = dateKey
	detail.followToday = dateKey == ZGT.TodayKey()
	ZGT.RefreshDetail()
end

local function EnterDay()
	local today = ZGT.TodayKey()
	local dateKey = today
	if detail.mode == "range" and detail.rangeEnd then
		dateKey = detail.rangeEnd
	elseif detail.mode == "day" and detail.selectedDate then
		dateKey = detail.selectedDate
	end
	SelectDate(dateKey)
end

local function EnterRange()
	if detail.mode == "range" then
		return
	end
	local today = ZGT.TodayKey()
	local oldest = ZGT.RetentionStart()
	local endKey = detail.selectedDate or today
	if detail.mode == "all" or endKey > today then
		endKey = today
	end
	if endKey < oldest then
		endKey = oldest
	end
	local startKey = ZGT.DateOffset(endKey, -(RANGE_PRESET - 1))
	if startKey < oldest then
		startKey = oldest
	end
	detail.mode = "range"
	detail.rangeStart = startKey
	detail.rangeEnd = endKey
	detail.rangeAnchor = nil
	detail.followToday = false
	ZGT.RefreshDetail()
end

local function EnterAll()
	if detail.mode == "all" then
		return
	end
	detail.mode = "all"
	detail.rangeAnchor = nil
	detail.followToday = true
	ZGT.RefreshDetail()
end

local function ShiftPeriod(delta)
	if detail.mode == "all" then
		return
	end
	local today = ZGT.TodayKey()
	local oldest = ZGT.RetentionStart()
	if detail.mode == "range" then
		local startKey = detail.rangeStart or today
		local endKey = detail.rangeEnd or startKey
		local nextStart = ZGT.DateOffset(startKey, delta)
		local nextEnd = ZGT.DateOffset(endKey, delta)
		if nextStart < oldest or nextEnd > today then
			return
		end
		local picking = detail.rangeAnchor ~= nil and startKey == endKey
		detail.rangeStart = nextStart
		detail.rangeEnd = nextEnd
		detail.rangeAnchor = picking and nextStart or nil
		ZGT.RefreshDetail()
		return
	end
	local dateKey = detail.selectedDate or today
	local shifted = ZGT.DateOffset(dateKey, delta)
	if shifted < oldest or shifted > today then
		return
	end
	SelectDate(shifted)
end

local function CanShift(delta, startKey, endKey)
	if detail.mode == "all" then
		return false
	end
	local today = ZGT.TodayKey()
	local oldest = ZGT.RetentionStart()
	local nextStart = ZGT.DateOffset(startKey, delta)
	local nextEnd = ZGT.DateOffset(endKey, delta)
	return nextStart >= oldest and nextEnd <= today
end

local function PlaceMarker(marker, x, y)
	marker:ClearAllPoints()
	marker:SetPoint("CENTER", detail.plot, "BOTTOMLEFT", x, y)
	marker:Show()
end

local function DateList(first, last, limit)
	local dates = {}
	if type(first) ~= "string" or type(last) ~= "string" then
		return dates
	end
	if first > last then
		first = last
	end
	local cursor = first
	while #dates < limit do
		dates[#dates + 1] = cursor
		if cursor >= last then
			break
		end
		local nextKey = ZGT.DateOffset(cursor, 1)
		if type(nextKey) ~= "string" or nextKey <= cursor then
			break
		end
		cursor = nextKey
	end
	return dates
end

local function ChartDates(rangeStart, rangeEnd)
	local today = ZGT.TodayKey()
	local oldest = ZGT.RetentionStart()
	if detail.mode == "range" or detail.mode == "all" then
		detail.chartEnd = today
		return DateList(oldest, today, ZGT.RetentionDays())
	end
	local windowEnd = detail.chartEnd
	if type(windowEnd) ~= "string" or windowEnd > today or windowEnd < oldest then
		windowEnd = today
	end
	local windowStart = ZGT.DateOffset(windowEnd, -(CHART_WINDOW - 1))
	if windowStart < oldest then
		windowStart = oldest
	end
	if rangeEnd > windowEnd or rangeStart < windowStart then
		windowEnd = rangeEnd
		if windowEnd > today then
			windowEnd = today
		end
		if windowEnd < oldest then
			windowEnd = oldest
		end
		windowStart = ZGT.DateOffset(windowEnd, -(CHART_WINDOW - 1))
		if windowStart < oldest then
			windowStart = oldest
			windowEnd = ZGT.DateOffset(windowStart, CHART_WINDOW - 1)
			if windowEnd > today then
				windowEnd = today
			end
		end
	end
	detail.chartEnd = windowEnd
	return DateList(windowStart, windowEnd, CHART_WINDOW)
end

local function LayoutColumns(count)
	if count < 1 then
		count = 1
	end
	local slot = PLOT_W / count
	if detail.chartLayoutCount == count then
		return slot
	end
	detail.chartLayoutCount = count
	for index = 1, #columns do
		local column = columns[index]
		if index <= count then
			column:Show()
			column:ClearAllPoints()
			column:SetSize(slot, PLOT_H)
			column:SetPoint("BOTTOMLEFT", detail.plot, "BOTTOMLEFT", (index - 1) * slot, 0)
		else
			column:Hide()
			column.dateKey = nil
			column.snapshot = nil
			if column.label then
				column.label:SetText("")
			end
		end
	end
	return slot
end

local function UpdateChart(scope, rangeStart, rangeEnd)
	local dates = ChartDates(rangeStart, rangeEnd)
	local count = #dates
	if count < 1 then
		return
	end
	local slot = LayoutColumns(count)
	local days = {}
	local minNet, maxValue = 0, 1
	for index = 1, count do
		local dateKey = dates[index]
		local view = ZGT.GetView(dateKey, scope)
		days[index] = view
		days[index].dateKey = dateKey
		local stack = (view.loot or 0) + (view.auctions or 0) + (view.vendor or 0)
		if stack > maxValue then
			maxValue = stack
		end
		if (view.net or 0) > maxValue then
			maxValue = view.net
		end
		if (view.net or 0) < minNet then
			minNet = view.net
		end
	end
	local span = maxValue - minNet
	if span <= 0 then
		span = 1
	end
	local function Y(value)
		local y = (value - minNet) / span * (PLOT_H - 2) + 1
		if y < 1 then
			return 1
		end
		if y > PLOT_H - 1 then
			return PLOT_H - 1
		end
		return y
	end
	local narrow = slot < 16
	local gap = slot >= 18 and 6 or (slot >= 10 and 2 or 1)
	local barWidth = math.max(slot - gap, 1)
	local barX = (slot - barWidth) / 2
	for index = 1, count do
		local column = columns[index]
		local view = days[index]
		column.dateKey = view.dateKey
		column.snapshot = view
		local inRange = view.dateKey >= rangeStart and view.dateKey <= rangeEnd
		local endpoint = view.dateKey == rangeStart or view.dateKey == rangeEnd
		if inRange then
			column.highlight:Show()
		else
			column.highlight:Hide()
		end
		local cursor = Y(0)
		local function Stack(texture, amount)
			local height = (amount or 0) / span * (PLOT_H - 2)
			if not amount or amount <= 0 or height < 1 then
				texture:Hide()
				return
			end
			texture:Show()
			texture:ClearAllPoints()
			texture:SetPoint("BOTTOMLEFT", column, "BOTTOMLEFT", barX, cursor)
			texture:SetSize(barWidth, height)
			cursor = cursor + height
		end
		Stack(column.loot, view.loot)
		Stack(column.auctions, view.auctions)
		Stack(column.vendor, view.vendor)
		local monthChanged = index == 1 or view.dateKey:sub(6, 7) ~= days[index - 1].dateKey:sub(6, 7)
		local dayNumber = tostring(tonumber(view.dateKey:sub(9, 10)))
		local showLabel = not narrow or index == 1 or view.dateKey:sub(9, 10) == "01"
		if showLabel then
			if monthChanged or narrow then
				dayNumber = tostring(tonumber(view.dateKey:sub(6, 7))) .. "/" .. dayNumber
			end
			column.label:SetText(dayNumber)
		else
			column.label:SetText("")
		end
		if endpoint then
			column.label:SetTextColor(1, 0.86, 0.4)
		else
			column.label:SetTextColor(0.55, 0.55, 0.58)
		end
	end
	for index = 1, #netMarkers do
		local marker = netMarkers[index]
		if index <= count then
			local endpoint = days[index].dateKey == rangeStart or days[index].dateKey == rangeEnd
			pcall(PlaceMarker, marker, (index - 0.5) * slot, Y(days[index].net or 0))
			if endpoint then
				marker:SetColorTexture(1, 0.86, 0.4, 1)
			else
				marker:SetColorTexture(0.95, 0.95, 0.98, 0.95)
			end
			local markerSize = slot >= 12 and 5 or 3
			marker:SetSize(markerSize, markerSize)
		else
			marker:Hide()
		end
	end
	local base = Y(0)
	detail.baseline:ClearAllPoints()
	detail.baseline:SetPoint("LEFT", detail.plot, "BOTTOMLEFT", 0, base)
	detail.baseline:SetPoint("RIGHT", detail.plot, "BOTTOMRIGHT", 0, base)
end

function ZGT.RefreshDetail()
	if not detail or not detail:IsShown() or not ZGT.DB or detail.refreshing then
		return
	end
	detail.refreshing = true
	local startKey, endKey = CurrentPeriod()
	local scope = detail.scope or "account"
	local comparison
	local view
	if detail.mode == "all" then
		view = ZGT.GetRangeView(startKey, endKey, scope)
	elseif startKey ~= endKey then
		comparison = ZGT.GetRangeComparison(startKey, endKey, scope)
		view = comparison.today
	else
		comparison = ZGT.GetComparison(startKey, scope)
		view = comparison.today
	end
	local color
	if comparison then
		color = ZGT.COLOR[comparison.direction] or ZGT.COLOR.flat
	elseif view.net > 0 then
		color = ZGT.COLOR.up
	elseif view.net < 0 then
		color = ZGT.COLOR.down
	else
		color = ZGT.COLOR.flat
	end
	local hex = ZGT.ColorHex(color)

	PaintScope(detail.accountButton, scope == "account")
	PaintScope(detail.characterButton, scope == "character")
	PaintScope(detail.dayButton, detail.mode ~= "range" and detail.mode ~= "all")
	PaintScope(detail.rangeButton, detail.mode == "range")
	PaintScope(detail.allButton, detail.mode == "all")
	detail.dateText:SetText(PeriodLabel(detail.mode, startKey, endKey))
	local canPrev = CanShift(-1, startKey, endKey)
	local canNext = CanShift(1, startKey, endKey)
	detail.prevButton.label:SetTextColor(canPrev and 1 or 0.4, canPrev and 0.82 or 0.4, canPrev and 0.25 or 0.4)
	detail.nextButton.label:SetTextColor(canNext and 1 or 0.4, canNext and 0.82 or 0.4, canNext and 0.25 or 0.4)

	local who
	if scope == "character" then
		local key = ZGT.GetCharacterKey()
		who = key and ("Character · " .. ShortName(key)) or "Character"
	else
		who = "Account · all characters"
	end
	detail.scopeText:SetText(who)

	local rateValue = comparison and comparison.todayRate or ZGT.GoldPerHour(view.net, view.played)
	local rate = rateValue and ZGT.FormatRate(rateValue) or "—"
	local percent = comparison and ZGT.FormatPercent(comparison.percent) or nil
	local summary = "|cff" .. hex .. ZGT.FormatMoney(view.net, true) .. "|r    |cff" .. hex .. rate .. "|r"
	if percent then
		local versus = startKey == endKey and "vs prior day" or ("vs prior " .. ZGT.SpanDays(startKey, endKey) .. " days")
		summary = summary .. "    |cff" .. hex .. percent .. "|r " .. versus
	end
	detail.summaryText:SetText(summary)
	detail.view = view
	detail.playedText:SetText("Played  " .. ZGT.FormatPlayed(view.played))

	for index = 1, #sourceRows do
		local row = sourceRows[index]
		row.value:SetText(ZGT.FormatMoney(SignedAmount(row.spec, view[row.spec.key])))
	end

	local characters = view.characters or {}
	detail.characterHeader:SetText(#characters > 0 and ("Characters (" .. #characters .. ")") or "Characters")
	local mine = ZGT.GetCharacterKey()
	for index = 1, #characterRows do
		local row = characterRows[index]
		local entry = characters[index]
		if entry then
			row:Show()
			row.snapshot = entry
			row.name:SetText(ShortName(entry.key))
			row.value:SetText(ZGT.FormatMoney(entry.net, true))
			local mineRow = entry.key == mine
			local tint = mineRow and { 1, 0.86, 0.4 } or ZGT.COLOR.text
			row.name:SetTextColor(tint[1], tint[2], tint[3])
			local valueColor = entry.net > 0 and ZGT.COLOR.up or entry.net < 0 and ZGT.COLOR.down or ZGT.COLOR.flat
			row.value:SetTextColor(valueColor[1], valueColor[2], valueColor[3])
		else
			row:Hide()
			row.snapshot = nil
		end
	end
	if #characters == 0 then
		characterRows[1]:Show()
		characterRows[1].snapshot = nil
		local periodWord = (startKey == endKey and detail.mode ~= "all") and "this day" or "this period"
		characterRows[1].name:SetText("No characters recorded " .. periodWord .. ".")
		characterRows[1].name:SetTextColor(ZGT.COLOR.muted[1], ZGT.COLOR.muted[2], ZGT.COLOR.muted[3])
		characterRows[1].value:SetText("")
	end

	local log = view.auctionsLog or {}
	local auctionTotal = view.auctionCount or #log
	detail.auctionHeader:SetText(auctionTotal > 0 and ("Auctions collected (" .. auctionTotal .. ")") or "Auctions collected")
	for index = 1, #auctionRows do
		local row = auctionRows[index]
		local entry = log[index]
		if entry then
			row:Show()
			local when = entry.clock or ""
			if startKey ~= endKey and type(entry.stamp) == "number" then
				when = date("%b %d  %H:%M", entry.stamp)
			end
			local whoName = scope == "account" and entry.character and ("  ·  " .. ShortName(entry.character)) or ""
			row.name:SetText(when .. "   " .. (entry.item or "Auction sale") .. whoName)
			row.name:SetTextColor(ZGT.COLOR.text[1], ZGT.COLOR.text[2], ZGT.COLOR.text[3])
			row.value:SetText(ZGT.FormatMoney(entry.copper or 0))
			row.snapshot = entry
		else
			row:Hide()
			row.snapshot = nil
		end
	end
	if #log == 0 then
		auctionRows[1]:Show()
		auctionRows[1].snapshot = nil
		local periodWord = (startKey == endKey and detail.mode ~= "all") and "this day" or "this period"
		auctionRows[1].name:SetText("No auction sales " .. periodWord .. ".")
		auctionRows[1].name:SetTextColor(ZGT.COLOR.muted[1], ZGT.COLOR.muted[2], ZGT.COLOR.muted[3])
		auctionRows[1].value:SetText("")
	else
		auctionRows[1].name:SetTextColor(ZGT.COLOR.text[1], ZGT.COLOR.text[2], ZGT.COLOR.text[3])
	end

	UpdateChart(scope, startKey, endKey)
	detail.refreshing = false
end

function ZGT.ToggleDetail()
	if not detail then
		return
	end
	if detail:IsShown() then
		detail:Hide()
		return
	end
	detail.mode = "day"
	detail.followToday = true
	detail.selectedDate = ZGT.TodayKey()
	detail.rangeAnchor = nil
	detail.chartEnd = nil
	detail.scope = detail.scope or "account"
	RestorePosition(detail)
	detail:Show()
	RaiseSpecial("ZoraGoldTrackerDetail")
	ZGT.RefreshDetail()
end

local function BuildDetail()
	detail = CreateFrame("Frame", "ZoraGoldTrackerDetail", UIParent, "BackdropTemplate")
	detail:SetSize(WIDTH, 534)
	detail:SetFrameStrata("DIALOG")
	detail:SetClampedToScreen(true)
	detail:SetMovable(true)
	detail:Hide()
	detail.scope = "account"
	detail.mode = "day"
	detail.followToday = true
	ZGT.ApplyBackdrop(detail, 0.96)
	RaiseSpecial("ZoraGoldTrackerDetail")

	local drag = CreateFrame("Frame", nil, detail)
	drag:SetPoint("TOPLEFT", 0, 0)
	drag:SetPoint("TOPRIGHT", -28, 0)
	drag:SetHeight(28)
	drag:EnableMouse(true)
	drag:RegisterForDrag("LeftButton")
	drag:SetScript("OnDragStart", function()
		detail:StartMoving()
	end)
	drag:SetScript("OnDragStop", function()
		detail:StopMovingOrSizing()
		SavePosition(detail)
	end)

	local title = Font(detail, "GameFontNormal", 14)
	title:SetPoint("TOPLEFT", 14, -8)
	title:SetText("Zora Gold Tracker")

	local close = CreateFrame("Button", nil, detail, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", 2, 2)

	detail.accountButton = FlatButton(detail, "Account", 84)
	detail.accountButton:SetPoint("TOPLEFT", 14, -34)
	detail.accountButton:SetScript("OnClick", function()
		detail.scope = "account"
		ZGT.RefreshDetail()
	end)
	detail.characterButton = FlatButton(detail, "Character", 92)
	detail.characterButton:SetPoint("LEFT", detail.accountButton, "RIGHT", 6, 0)
	detail.characterButton:SetScript("OnClick", function()
		detail.scope = "character"
		ZGT.RefreshDetail()
	end)

	detail.dayButton = FlatButton(detail, "Day", 46)
	detail.dayButton:SetPoint("LEFT", detail.characterButton, "RIGHT", 12, 0)
	detail.dayButton:SetScript("OnClick", EnterDay)
	ButtonTip(detail.dayButton, "One day. Hover a bar to choose it.")
	detail.rangeButton = FlatButton(detail, "Range", 62)
	detail.rangeButton:SetPoint("LEFT", detail.dayButton, "RIGHT", 4, 0)
	detail.rangeButton:SetScript("OnClick", EnterRange)
	ButtonTip(detail.rangeButton, "Starts as 7 days. Click one bar, then another, to choose the span. Arrows slide it.")
	detail.allButton = FlatButton(detail, "All", 46)
	detail.allButton:SetPoint("LEFT", detail.rangeButton, "RIGHT", 4, 0)
	detail.allButton:SetScript("OnClick", EnterAll)
	ButtonTip(detail.allButton, "Every day still stored. History is kept for " .. ZGT.RetentionDays() .. " days.")

	detail.nextButton = FlatButton(detail, ">", 22)
	detail.nextButton:SetPoint("TOPRIGHT", -14, -62)
	detail.nextButton:SetScript("OnClick", function()
		ShiftPeriod(1)
	end)
	detail.dateText = Font(detail, "GameFontHighlightSmall")
	detail.dateText:SetPoint("RIGHT", detail.nextButton, "LEFT", -6, 0)
	detail.dateText:SetJustifyH("RIGHT")
	detail.prevButton = FlatButton(detail, "<", 22)
	detail.prevButton:SetPoint("RIGHT", detail.dateText, "LEFT", -6, 0)
	detail.prevButton:SetScript("OnClick", function()
		ShiftPeriod(-1)
	end)

	detail.scopeText = Font(detail, "GameFontHighlightSmall", nil, ZGT.COLOR.muted[1], ZGT.COLOR.muted[2], ZGT.COLOR.muted[3])
	detail.scopeText:SetPoint("LEFT", detail, "TOPLEFT", 16, -72)
	detail.scopeText:SetPoint("RIGHT", detail.prevButton, "LEFT", -10, 0)
	detail.summaryText = Font(detail, "GameFontNormal")
	detail.summaryText:SetPoint("TOPLEFT", 16, -90)
	detail.summaryText:SetWidth(WIDTH - 32)
	detail.playedText = Font(detail, "GameFontHighlightSmall", nil, ZGT.COLOR.muted[1], ZGT.COLOR.muted[2], ZGT.COLOR.muted[3])
	detail.playedText:SetPoint("TOPLEFT", 16, -110)

	local incomeHeader = Font(detail, "GameFontNormalSmall", nil, 0.9, 0.76, 0.35)
	incomeHeader:SetPoint("TOPLEFT", 16, -132)
	incomeHeader:SetText("Income")
	local spentHeader = Font(detail, "GameFontNormalSmall", nil, 0.9, 0.76, 0.35)
	spentHeader:SetPoint("TOPLEFT", 270, -132)
	spentHeader:SetText("Spent")

	local function BuildSourceColumn(rows, originX, valueX, labelWidth, valueWidth)
		for index = 1, #rows do
			local spec = rows[index]
			local y = -150 - (index - 1) * 16
			local swatch = detail:CreateTexture(nil, "ARTWORK")
			swatch:SetSize(8, 8)
			swatch:SetPoint("TOPLEFT", originX, y - 3)
			ZGT.Paint(swatch, ZGT.COLOR[spec.color], 1)
			local label = Font(detail, "GameFontHighlightSmall")
			label:SetPoint("TOPLEFT", originX + 14, y)
			label:SetWidth(labelWidth)
			label:SetText(spec.label)
			local value = Font(detail, "GameFontHighlightSmall")
			value:SetWidth(valueWidth)
			value:SetPoint("TOPRIGHT", valueX, y)
			value:SetJustifyH("RIGHT")
			value:SetTextColor(ZGT.COLOR[spec.color][1], ZGT.COLOR[spec.color][2], ZGT.COLOR[spec.color][3])
			sourceRows[#sourceRows + 1] = { spec = spec, label = label, value = value }
			if spec.key == "training" then
				local hit = CreateFrame("Frame", nil, detail)
				hit:SetPoint("TOPLEFT", detail, "TOPLEFT", originX, y)
				hit:SetPoint("TOPRIGHT", detail, "TOPRIGHT", valueX, y)
				hit:SetHeight(14)
				hit:EnableMouse(true)
				hit:SetScript("OnEnter", function(self)
					ShowTrainingTip(self)
				end)
				hit:SetScript("OnLeave", function()
					GameTooltip:Hide()
				end)
			end
		end
	end
	BuildSourceColumn(INCOME_ROWS, 16, -270, 100, 112)
	BuildSourceColumn(SPEND_ROWS, 270, -16, 100, 120)

	detail.characterHeader = Font(detail, "GameFontNormalSmall", nil, 0.9, 0.76, 0.35)
	detail.characterHeader:SetPoint("TOPLEFT", 16, -284)
	detail.characterHeader:SetText("Characters")
	for index = 1, 4 do
		local row = CreateFrame("Frame", nil, detail)
		row:SetSize(WIDTH - 32, 16)
		row:SetPoint("TOPLEFT", 16, -300 - (index - 1) * 16)
		row:EnableMouse(true)
		row.name = Font(row, "GameFontHighlightSmall")
		row.name:SetPoint("LEFT", 0, 0)
		row.name:SetWidth(250)
		row.value = Font(row, "GameFontHighlightSmall")
		row.value:SetPoint("RIGHT", 0, 0)
		row.value:SetJustifyH("RIGHT")
		row:SetScript("OnEnter", function(self)
			ShowCharacterTip(self)
		end)
		row:SetScript("OnLeave", function()
			GameTooltip:Hide()
		end)
		characterRows[index] = row
	end

	detail.auctionHeader = Font(detail, "GameFontNormalSmall", nil, 0.9, 0.76, 0.35)
	detail.auctionHeader:SetPoint("TOPLEFT", 16, -368)
	detail.auctionHeader:SetText("Auctions collected")
	detail.salesButton = FlatButton(detail, "All sales", 64)
	detail.salesButton:SetPoint("TOPRIGHT", -16, -363)
	detail.salesButton:SetScript("OnClick", function()
		if ZGT.ToggleSales then
			ZGT.ToggleSales()
		end
	end)
	PaintScope(detail.salesButton, false)
	ButtonTip(detail.salesButton, "Every stored auction sale, grouped by day.")
	for index = 1, 2 do
		local row = CreateFrame("Frame", nil, detail)
		row:SetSize(WIDTH - 32, 16)
		row:SetPoint("TOPLEFT", 16, -384 - (index - 1) * 16)
		row:EnableMouse(true)
		row.name = Font(row, "GameFontHighlightSmall")
		row.name:SetPoint("LEFT", 0, 0)
		row.name:SetPoint("RIGHT", -150, 0)
		row.value = Font(row, "GameFontHighlightSmall")
		row.value:SetPoint("RIGHT", 0, 0)
		row.value:SetJustifyH("RIGHT")
		row.value:SetTextColor(ZGT.COLOR.auctions[1], ZGT.COLOR.auctions[2], ZGT.COLOR.auctions[3])
		row:SetScript("OnEnter", function(self)
			if not self.snapshot or not self.snapshot.item then
				GameTooltip:Hide()
				return
			end
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:ClearLines()
			GameTooltip:AddLine(self.snapshot.item, 1, 0.86, 0.4)
			GameTooltip:AddLine(ZGT.FormatMoney(self.snapshot.copper or 0), 1, 1, 1)
			if self.snapshot.character then
				GameTooltip:AddLine(ShortName(self.snapshot.character), 0.7, 0.7, 0.7)
			end
			GameTooltip:Show()
		end)
		row:SetScript("OnLeave", function()
			GameTooltip:Hide()
		end)
		auctionRows[index] = row
	end

	detail.legend = Font(detail, "GameFontHighlightSmall", 10)
	detail.legend:SetPoint("TOPLEFT", 16, -420)
	detail.legend:SetText("|cffd9b333Loot|r   |cff599ef9Auctions|r   |cfff28c33Vendored|r   |cfff2f2faNet|r")

	local chart = CreateFrame("Frame", nil, detail)
	chart:SetPoint("TOPLEFT", 16, -436)
	chart:SetSize(PLOT_W, PLOT_H + 14)
	local plot = CreateFrame("Frame", nil, chart)
	plot:SetPoint("TOPLEFT", 0, 0)
	plot:SetSize(PLOT_W, PLOT_H)
	detail.plot = plot
	detail.baseline = plot:CreateTexture(nil, "BORDER")
	detail.baseline:SetHeight(1)
	ZGT.Paint(detail.baseline, { 1, 1, 1 }, 0.22)

	local chartCap = ZGT.RetentionDays()
	local slot = PLOT_W / CHART_WINDOW
	for index = 1, chartCap do
		local column = CreateFrame("Frame", nil, plot)
		column:SetSize(slot, PLOT_H)
		column:EnableMouse(true)
		if index <= CHART_WINDOW then
			column:SetPoint("BOTTOMLEFT", plot, "BOTTOMLEFT", (index - 1) * slot, 0)
		else
			column:Hide()
		end
		column.highlight = column:CreateTexture(nil, "BACKGROUND")
		column.highlight:SetAllPoints()
		ZGT.Paint(column.highlight, { 1, 0.82, 0 }, 0.16)
		column.highlight:Hide()
		column.loot = column:CreateTexture(nil, "ARTWORK")
		ZGT.Paint(column.loot, ZGT.COLOR.loot, 0.95)
		column.auctions = column:CreateTexture(nil, "ARTWORK")
		ZGT.Paint(column.auctions, ZGT.COLOR.auctions, 0.95)
		column.vendor = column:CreateTexture(nil, "ARTWORK")
		ZGT.Paint(column.vendor, ZGT.COLOR.vendor, 0.95)
		column.label = Font(chart, "GameFontHighlightSmall", 8, 0.55, 0.55, 0.58)
		column.label:SetPoint("TOP", column, "BOTTOM", 0, -1)
		column.label:SetJustifyH("CENTER")
		column:SetScript("OnEnter", function(self)
			if not self.dateKey or detail.refreshing then
				return
			end
			if (detail.mode or "day") == "day" and self.dateKey ~= detail.selectedDate then
				SelectDate(self.dateKey)
			end
			ShowDayTip(self)
		end)
		column:SetScript("OnLeave", function()
			GameTooltip:Hide()
		end)
		column:SetScript("OnMouseDown", function(self, button)
			if button ~= "LeftButton" or not self.dateKey or detail.mode ~= "range" then
				return
			end
			local anchor = detail.rangeAnchor
			local dateKey = self.dateKey
			if not anchor or anchor == dateKey then
				detail.rangeAnchor = dateKey
				detail.rangeStart = dateKey
				detail.rangeEnd = dateKey
			elseif anchor < dateKey then
				detail.rangeStart = anchor
				detail.rangeEnd = dateKey
				detail.rangeAnchor = nil
			else
				detail.rangeStart = dateKey
				detail.rangeEnd = anchor
				detail.rangeAnchor = nil
			end
			detail.followToday = false
			ZGT.RefreshDetail()
			ShowDayTip(self)
		end)
		columns[index] = column
	end
	for index = 1, chartCap do
		local marker = plot:CreateTexture(nil, "OVERLAY")
		marker:SetSize(5, 5)
		marker:SetColorTexture(0.95, 0.95, 0.98, 0.95)
		marker:Hide()
		netMarkers[index] = marker
	end

	detail:SetScript("OnShow", function()
		RaiseSpecial("ZoraGoldTrackerDetail")
	end)
end

BuildDetail()

-- Helpers shared with Sales.lua, which loads after this file.
ZGT.UI = {
	Font = Font,
	FlatButton = FlatButton,
	PaintScope = PaintScope,
	ButtonTip = ButtonTip,
	ShortName = ShortName,
	DateLabel = DateLabel,
	GetScope = function()
		return detail and detail.scope or "account"
	end,
}

local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:SetScript("OnEvent", function(_, _, name)
	if name ~= "ZoraGoldTracker" then
		return
	end
	loader:UnregisterEvent("ADDON_LOADED")
	ZGT.AddListener(ZGT.RefreshDetail)
end)
