ZoraGoldTracker = ZoraGoldTracker or {}
local ZGT = ZoraGoldTracker

local ADDON_NAME = "ZoraGoldTracker"
local CONTEXT_TTL = 1.25
local MAIL_TTL = 5
local PLAYED_INTERVAL = 5
local RETENTION_DAYS = 90
local AUCTION_LOG_CAP = 50

ZGT.MIN_RATE_SECONDS = 60
ZGT.listeners = ZGT.listeners or {}

local INCOME_FIELDS = { "loot", "auctions", "vendor", "quests", "other" }
local SPEND_FIELDS = { "auctionBuy", "deposit", "flight", "repairs", "vendorBuy", "training", "spent" }
local DAY_FIELDS = {
	"loot", "auctions", "vendor", "quests", "other",
	"auctionBuy", "deposit", "flight", "repairs", "vendorBuy", "training", "spent",
	"played",
}
local SPEND_SET = {}
local SPEND_LABEL = {
	auctionBuy = "Auction buy",
	deposit = "Deposit",
	flight = "Flight path",
	repairs = "Repair",
	vendorBuy = "Vendor",
	training = "Training",
	spent = "Spent",
}
for index = 1, #SPEND_FIELDS do
	SPEND_SET[SPEND_FIELDS[index]] = true
end
local POINTS = {
	TOPLEFT = true, TOP = true, TOPRIGHT = true,
	LEFT = true, CENTER = true, RIGHT = true,
	BOTTOMLEFT = true, BOTTOM = true, BOTTOMRIGHT = true,
}

local pending
local lastMoney
local repairQuote
local inWorld = false
local entered = false
local worldGen = 0
local elapsed = 0
local characterKey
local lootOpen = false
local lootClosedAt = 0
local wrapped = {}

local eventFrame = CreateFrame("Frame")

local function TodayKey()
	return date("%Y-%m-%d")
end

local function BlankDay()
	local day = {
		auctionsLog = {},
		characters = {},
		trainingBy = {},
	}
	for index = 1, #DAY_FIELDS do
		day[DAY_FIELDS[index]] = 0
	end
	return day
end

local function NormalizeDay(day)
	for _, field in ipairs(DAY_FIELDS) do
		if type(day[field]) ~= "number" then
			day[field] = 0
		end
	end
	if type(day.auctionsLog) ~= "table" then
		day.auctionsLog = {}
	end
	if type(day.trainingBy) ~= "table" then
		day.trainingBy = {}
	end
	return day
end

local function NormalizeSession(session)
	if type(session) ~= "table" then
		return { net = 0, played = 0 }
	end
	if type(session.net) ~= "number" then
		session.net = 0
	end
	if type(session.played) ~= "number" then
		session.played = 0
	end
	return session
end

function ZGT.TodayKey()
	return TodayKey()
end

function ZGT.DateOffset(dateKey, offsetDays)
	local year, month, day = tostring(dateKey or ""):match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
	year, month, day = tonumber(year), tonumber(month), tonumber(day)
	if not year then
		return TodayKey()
	end
	local stamp = time({ year = year, month = month, day = day + offsetDays, hour = 12 })
	if not stamp then
		return TodayKey()
	end
	return date("%Y-%m-%d", stamp)
end

function ZGT.RetentionDays()
	return RETENTION_DAYS
end

function ZGT.AuctionLogCap()
	return AUCTION_LOG_CAP
end

function ZGT.RetentionStart()
	return ZGT.DateOffset(TodayKey(), -(RETENTION_DAYS - 1))
end

function ZGT.SpanDays(startKey, endKey)
	if type(startKey) ~= "string" or type(endKey) ~= "string" then
		return 1
	end
	if startKey > endKey then
		startKey, endKey = endKey, startKey
	end
	local count = 1
	local cursor = startKey
	while cursor < endKey and count <= RETENTION_DAYS + 2 do
		local nextKey = ZGT.DateOffset(cursor, 1)
		if type(nextKey) ~= "string" or nextKey <= cursor then
			break
		end
		cursor = nextKey
		count = count + 1
	end
	return count
end

function ZGT.OldestStoredDate()
	local oldest
	local cutoff = ZGT.RetentionStart()
	local today = TodayKey()
	if ZGT.DB and type(ZGT.DB.characters) == "table" then
		for _, record in pairs(ZGT.DB.characters) do
			if type(record) == "table" and type(record.days) == "table" then
				for dateKey in pairs(record.days) do
					if type(dateKey) == "string" and dateKey:match("^%d%d%d%d%-%d%d%-%d%d$") and dateKey >= cutoff and dateKey <= today then
						if not oldest or dateKey < oldest then
							oldest = dateKey
						end
					end
				end
			end
		end
	end
	return oldest or today
end

function ZGT.AddListener(callback)
	ZGT.listeners[#ZGT.listeners + 1] = callback
end

function ZGT.Notify()
	for index = 1, #ZGT.listeners do
		local ok, err = pcall(ZGT.listeners[index])
		if not ok and geterrorhandler then
			geterrorhandler()(err)
		end
	end
end

function ZGT.GetCharacterKey()
	return characterKey
end

function ZGT.GetSettings()
	return ZGT.DB and ZGT.DB.settings or {}
end

function ZGT.Net(day)
	day = day or {}
	local net = 0
	for index = 1, #INCOME_FIELDS do
		net = net + (day[INCOME_FIELDS[index]] or 0)
	end
	for index = 1, #SPEND_FIELDS do
		net = net - (day[SPEND_FIELDS[index]] or 0)
	end
	return net
end

function ZGT.GoldPerHour(net, played)
	if type(net) ~= "number" or type(played) ~= "number" then
		return nil
	end
	if played < ZGT.MIN_RATE_SECONDS then
		return nil
	end
	return net / (played / 3600)
end

function ZGT.GetSession()
	local session = ZGT.DB and ZGT.DB.session
	if type(session) ~= "table" then
		return 0, 0
	end
	return session.net or 0, session.played or 0
end

local function ReadableToken(value)
	if not ZGT.IsReadable(value) or type(value) ~= "string" or value == "" or value == "Unknown" then
		return nil
	end
	return value
end

local function CallName(func, ...)
	if type(func) ~= "function" then
		return nil
	end
	local ok, name, second = pcall(func, ...)
	if not ok then
		return nil
	end
	return name, second
end

local function RealmLabelSet()
	local labels = {}
	local function add(value)
		value = ReadableToken(value)
		if not value then
			return
		end
		labels[value] = true
		labels[value:lower()] = true
		local compact = value:gsub("%s+", "")
		labels[compact] = true
		labels[compact:lower()] = true
	end
	local realm = select(1, CallName(GetRealmName))
	add(realm)
	local normalized = select(1, CallName(GetNormalizedRealmName))
	add(normalized)
	return labels
end

local function IsRealmLabel(value, labels)
	if type(value) ~= "string" or value == "" then
		return false
	end
	if labels[value] or labels[value:lower()] then
		return true
	end
	local compact = value:gsub("%s+", "")
	return labels[compact] or labels[compact:lower()] or false
end

-- Forever's UnitName / UnitFullName return the first name and the surname.
-- The surname is not a realm. GetRealmName() is a separate ruleset label and
-- is empty often enough that storing it produced a second "Name-Unknown" row.
local function KeyFromNamePair(name, second, labels)
	name = ReadableToken(name)
	if not name then
		return nil
	end
	local first, rest = name:match("^(%S+)%s+(.+)$")
	if first and rest and not IsRealmLabel(rest, labels) then
		return first .. "-" .. rest
	end
	second = ReadableToken(second)
	if second and not IsRealmLabel(second, labels) then
		return name .. "-" .. second
	end
	return nil
end

local function ResolveCharacterKey()
	local labels = RealmLabelSet()
	local name, second = CallName(UnitFullName, "player")
	local key = KeyFromNamePair(name, second, labels)
	if not key then
		name, second = CallName(UnitNameUnmodified, "player")
		key = KeyFromNamePair(name, second, labels)
	end
	if not key then
		name, second = CallName(UnitName, "player")
		key = KeyFromNamePair(name, second, labels)
	end
	if not key then
		name = CallName(GetUnitName, "player", true)
		key = KeyFromNamePair(name, nil, labels)
	end
	if key then
		return key, true
	end
	name = ReadableToken(select(1, CallName(UnitName, "player")))
	local realm = ReadableToken(select(1, CallName(GetRealmName)))
	if not name or not realm then
		return nil
	end
	return name .. "-" .. realm, false
end

local function CharacterRecord(key)
	local characters = ZGT.DB.characters
	local record = characters[key]
	if type(record) ~= "table" then
		record = {}
		characters[key] = record
	end
	if type(record.days) ~= "table" then
		record.days = {}
	end
	return record
end

local function DayBucket(key, dateKey)
	local record = CharacterRecord(key)
	local day = record.days[dateKey]
	if type(day) ~= "table" then
		day = {}
		record.days[dateKey] = day
	end
	return NormalizeDay(day)
end

local function CopyLogEntry(entry, key)
	if type(entry) ~= "table" then
		return nil
	end
	return {
		item = entry.item,
		copper = entry.copper,
		clock = entry.clock,
		stamp = entry.stamp,
		character = key,
	}
end

local function AppendLog(log, entry, key)
	local copy = CopyLogEntry(entry, key)
	if copy then
		log[#log + 1] = copy
	end
end

-- `training` is the total. `trainingBy` splits it by skill line and never
-- feeds Net, so a missing or partial split cannot change the day's net.
local function CopyTraining(target, day)
	local copy = {}
	if type(day.trainingBy) == "table" then
		for skill, amount in pairs(day.trainingBy) do
			if type(skill) == "string" and type(amount) == "number" then
				copy[skill] = amount
			end
		end
	end
	target.trainingBy = copy
end

local function AddTraining(target, day)
	if type(target.trainingBy) ~= "table" then
		target.trainingBy = {}
	end
	if type(day.trainingBy) ~= "table" then
		return
	end
	for skill, amount in pairs(day.trainingBy) do
		if type(skill) == "string" and type(amount) == "number" then
			target.trainingBy[skill] = (target.trainingBy[skill] or 0) + amount
		end
	end
end

local function CopyAmounts(target, day)
	for index = 1, #DAY_FIELDS do
		local field = DAY_FIELDS[index]
		target[field] = day[field] or 0
	end
	CopyTraining(target, day)
end

local function AddAmounts(target, day)
	for index = 1, #DAY_FIELDS do
		local field = DAY_FIELDS[index]
		target[field] = (target[field] or 0) + (day[field] or 0)
	end
	AddTraining(target, day)
end

local function CharacterParts(key)
	local first, suffix = tostring(key or ""):match("^(.-)%-(.+)$")
	if not first or first == "" or not suffix or suffix == "" then
		return nil
	end
	return first, suffix
end

local function IsLegacySuffix(suffix, labels)
	if suffix == "Unknown" or suffix:find("%s") then
		return true
	end
	return IsRealmLabel(suffix, labels)
end

local function MergeDay(intoDay, fromDay)
	intoDay = NormalizeDay(intoDay)
	fromDay = NormalizeDay(fromDay)
	AddAmounts(intoDay, fromDay)
	local log = intoDay.auctionsLog
	for index = 1, #fromDay.auctionsLog do
		local entry = fromDay.auctionsLog[index]
		if type(entry) == "table" then
			log[#log + 1] = entry
		end
	end
	table.sort(log, function(a, b)
		return (a.stamp or 0) < (b.stamp or 0)
	end)
	while #log > AUCTION_LOG_CAP do
		table.remove(log, 1)
	end
end

local function MergeCharacter(fromKey, intoKey)
	if fromKey == intoKey or not ZGT.DB or type(ZGT.DB.characters) ~= "table" then
		return
	end
	local characters = ZGT.DB.characters
	local source = characters[fromKey]
	characters[fromKey] = nil
	if type(source) ~= "table" or type(source.days) ~= "table" then
		return
	end
	local record = CharacterRecord(intoKey)
	for dateKey, day in pairs(source.days) do
		if type(dateKey) == "string" and type(day) == "table" then
			local existing = record.days[dateKey]
			if type(existing) ~= "table" then
				record.days[dateKey] = day
			else
				MergeDay(existing, day)
			end
		end
	end
end

local function CoalesceCharacters(preferredKey)
	if not ZGT.DB or type(ZGT.DB.characters) ~= "table" then
		return
	end
	local labels = RealmLabelSet()
	local groups = {}
	local function add(key)
		local first = CharacterParts(key)
		if not first then
			return
		end
		local group = groups[first]
		if not group then
			group = {}
			groups[first] = group
		end
		for index = 1, #group do
			if group[index] == key then
				return
			end
		end
		group[#group + 1] = key
	end
	for key in pairs(ZGT.DB.characters) do
		if type(key) == "string" then
			add(key)
		end
	end
	if type(preferredKey) == "string" then
		add(preferredKey)
	end
	for _, group in pairs(groups) do
		local unknownKey
		local legacy = {}
		local other = {}
		local preferred
		for index = 1, #group do
			local key = group[index]
			local _, suffix = CharacterParts(key)
			if preferredKey and key == preferredKey then
				preferred = key
			elseif suffix == "Unknown" then
				unknownKey = key
			elseif IsLegacySuffix(suffix, labels) then
				legacy[#legacy + 1] = key
			else
				other[#other + 1] = key
			end
		end
		if preferred then
			-- Old rows carry only a first name and a realm label, so they cannot say which
			-- surname they belonged to. Fold them in only when this is the sole surname on that first name.
			if #other == 0 then
				if unknownKey then
					MergeCharacter(unknownKey, preferred)
				end
				for index = 1, #legacy do
					MergeCharacter(legacy[index], preferred)
				end
			end
		elseif unknownKey and #legacy == 1 and #other == 0 then
			MergeCharacter(unknownKey, legacy[1])
		elseif unknownKey and #other == 1 and #legacy == 0 then
			MergeCharacter(unknownKey, other[1])
		end
	end
end

function ZGT.GetView(dateKey, scope)
	local view = BlankDay()
	if not ZGT.DB then
		view.net = 0
		return view
	end
	local characters = {}
	local mergedLog = {}
	for key, record in pairs(ZGT.DB.characters) do
		local day = type(record) == "table" and type(record.days) == "table" and record.days[dateKey] or nil
		if type(day) == "table" then
			day = NormalizeDay(day)
			local row = { key = key }
			CopyAmounts(row, day)
			row.net = ZGT.Net(row)
			characters[#characters + 1] = row
			for index = 1, #day.auctionsLog do
				AppendLog(mergedLog, day.auctionsLog[index], key)
			end
			if scope ~= "character" then
				AddAmounts(view, day)
			end
		end
	end
	table.sort(characters, function(a, b)
		if a.net == b.net then
			return a.key < b.key
		end
		return a.net > b.net
	end)
	table.sort(mergedLog, function(a, b)
		return (a.stamp or 0) > (b.stamp or 0)
	end)
	while #mergedLog > AUCTION_LOG_CAP do
		mergedLog[#mergedLog] = nil
	end
	view.characters = characters
	if scope == "character" then
		local key = characterKey
		local record = key and ZGT.DB.characters[key]
		local day = record and record.days and record.days[dateKey]
		if type(day) == "table" then
			day = NormalizeDay(day)
			CopyAmounts(view, day)
			view.auctionsLog = {}
			for index = 1, #day.auctionsLog do
				AppendLog(view.auctionsLog, day.auctionsLog[index], key)
			end
			table.sort(view.auctionsLog, function(a, b)
				return (a.stamp or 0) > (b.stamp or 0)
			end)
		end
	else
		view.auctionsLog = mergedLog
	end
	view.net = ZGT.Net(view)
	return view
end

local function TrimLog(log)
	table.sort(log, function(a, b)
		return (a.stamp or 0) > (b.stamp or 0)
	end)
	local count = #log
	while #log > AUCTION_LOG_CAP do
		log[#log] = nil
	end
	return count
end

function ZGT.GetRangeView(startKey, endKey, scope)
	if type(startKey) ~= "string" or type(endKey) ~= "string" then
		startKey = TodayKey()
		endKey = startKey
	elseif startKey > endKey then
		startKey, endKey = endKey, startKey
	end
	local view = BlankDay()
	view.spanStart = startKey
	view.spanEnd = endKey
	view.auctionCount = 0
	if not ZGT.DB or type(ZGT.DB.characters) ~= "table" then
		view.net = 0
		view.characters = {}
		return view
	end
	local byCharacter = {}
	local mergedLog = {}
	for key, record in pairs(ZGT.DB.characters) do
		local days = type(record) == "table" and record.days
		if type(days) == "table" then
			for dateKey, day in pairs(days) do
				if type(dateKey) == "string" and dateKey:match("^%d%d%d%d%-%d%d%-%d%d$") and dateKey >= startKey and dateKey <= endKey and type(day) == "table" then
					day = NormalizeDay(day)
					local row = byCharacter[key]
					if not row then
						row = { key = key }
						for index = 1, #DAY_FIELDS do
							row[DAY_FIELDS[index]] = 0
						end
						byCharacter[key] = row
					end
					AddAmounts(row, day)
					if scope ~= "character" or key == characterKey then
						for index = 1, #day.auctionsLog do
							AppendLog(mergedLog, day.auctionsLog[index], key)
						end
					end
				end
			end
		end
	end
	local characters = {}
	for _, row in pairs(byCharacter) do
		row.net = ZGT.Net(row)
		characters[#characters + 1] = row
		if scope ~= "character" then
			AddAmounts(view, row)
		end
	end
	if scope == "character" then
		local row = characterKey and byCharacter[characterKey]
		if row then
			CopyAmounts(view, row)
		end
	end
	table.sort(characters, function(a, b)
		if a.net == b.net then
			return a.key < b.key
		end
		return a.net > b.net
	end)
	view.auctionCount = TrimLog(mergedLog)
	view.characters = characters
	view.auctionsLog = mergedLog
	view.net = ZGT.Net(view)
	return view
end

-- Every stored auction sale inside the retention window, grouped by day, newest day first.
-- Each group is { dateKey, total, entries }, with entries newest first. Read only: it does not
-- call NormalizeDay, so it never writes defaults into the saved days.
function ZGT.GetAuctionDays(scope)
	local days = {}
	if not ZGT.DB or type(ZGT.DB.characters) ~= "table" then
		return days
	end
	local cutoff = ZGT.RetentionStart()
	local today = TodayKey()
	local byDate = {}
	for key, record in pairs(ZGT.DB.characters) do
		if (scope ~= "character" or key == characterKey) and type(record) == "table" and type(record.days) == "table" then
			for dateKey, day in pairs(record.days) do
				if type(dateKey) == "string" and dateKey:match("^%d%d%d%d%-%d%d%-%d%d$") and dateKey >= cutoff and dateKey <= today
					and type(day) == "table" and type(day.auctionsLog) == "table" then
					for index = 1, #day.auctionsLog do
						local copy = CopyLogEntry(day.auctionsLog[index], key)
						if copy then
							local group = byDate[dateKey]
							if not group then
								group = { dateKey = dateKey, total = 0, entries = {} }
								byDate[dateKey] = group
								days[#days + 1] = group
							end
							group.entries[#group.entries + 1] = copy
							group.total = group.total + (ZGT.AsNumber(copy.copper) or 0)
						end
					end
				end
			end
		end
	end
	table.sort(days, function(a, b)
		return a.dateKey > b.dateKey
	end)
	for index = 1, #days do
		table.sort(days[index].entries, function(a, b)
			return (a.stamp or 0) > (b.stamp or 0)
		end)
	end
	return days
end

local function CompareViews(current, previous)
	local currentRate = ZGT.GoldPerHour(current.net, current.played)
	local previousRate = ZGT.GoldPerHour(previous.net, previous.played)
	local percent
	local direction
	if currentRate and previousRate then
		local diff = currentRate - previousRate
		if math.abs(diff) < 0.5 then
			direction = "flat"
		elseif diff > 0 then
			direction = "up"
		else
			direction = "down"
		end
		if previousRate ~= 0 then
			percent = (currentRate - previousRate) / math.abs(previousRate) * 100
		end
	elseif current.net > 0 then
		direction = "up"
	elseif current.net < 0 then
		direction = "down"
	else
		direction = "flat"
	end
	return currentRate, previousRate, percent, direction
end

function ZGT.GetComparison(dateKey, scope)
	local current = ZGT.GetView(dateKey, scope)
	local previous = ZGT.GetView(ZGT.DateOffset(dateKey, -1), scope)
	local currentRate, previousRate, percent, direction = CompareViews(current, previous)
	return {
		today = current,
		previous = previous,
		todayRate = currentRate,
		previousRate = previousRate,
		percent = percent,
		direction = direction,
	}
end

function ZGT.GetRangeComparison(startKey, endKey, scope)
	if type(startKey) ~= "string" or type(endKey) ~= "string" then
		startKey = TodayKey()
		endKey = startKey
	elseif startKey > endKey then
		startKey, endKey = endKey, startKey
	end
	local current = ZGT.GetRangeView(startKey, endKey, scope)
	local span = ZGT.SpanDays(startKey, endKey)
	local priorEnd = ZGT.DateOffset(startKey, -1)
	local priorStart = ZGT.DateOffset(priorEnd, -(span - 1))
	local comparable = type(priorStart) == "string" and priorStart >= ZGT.RetentionStart()
	local previous = comparable and ZGT.GetRangeView(priorStart, priorEnd, scope) or BlankDay()
	previous.net = ZGT.Net(previous)
	local currentRate, previousRate, percent, direction = CompareViews(current, previous)
	if not comparable then
		percent = nil
	end
	return {
		today = current,
		previous = previous,
		todayRate = currentRate,
		previousRate = previousRate,
		percent = percent,
		direction = direction,
		span = span,
		comparable = comparable,
	}
end

local function Prune()
	local cutoff = ZGT.RetentionStart()
	if type(cutoff) ~= "string" or cutoff >= TodayKey() then
		return
	end
	for key, record in pairs(ZGT.DB.characters) do
		if type(record) ~= "table" or type(record.days) ~= "table" then
			ZGT.DB.characters[key] = nil
		else
			for dateKey in pairs(record.days) do
				if type(dateKey) ~= "string" or not dateKey:match("^%d%d%d%d%-%d%d%-%d%d$") or dateKey < cutoff then
					record.days[dateKey] = nil
				end
			end
		end
	end
end

local function InitDB()
	if type(ZoraGoldTrackerDB) ~= "table" then
		ZoraGoldTrackerDB = {}
	end
	local db = ZoraGoldTrackerDB
	db.version = 1
	if type(db.characters) ~= "table" then
		db.characters = {}
	end
	if type(db.settings) ~= "table" then
		db.settings = {}
	end
	local settings = db.settings
	if type(settings.locked) ~= "boolean" then
		settings.locked = false
	end
	if type(settings.tickerHidden) ~= "boolean" then
		settings.tickerHidden = false
	end
	if type(settings.tickerScale) ~= "number" then
		settings.tickerScale = 1
	end
	if type(db.session) ~= "table" then
		db.session = nil
	else
		NormalizeSession(db.session)
	end
	ZGT.DB = db
	Prune()
	CoalesceCharacters()
end

local function SetContext(source, extra, ttl)
	pending = {
		source = source,
		expires = GetTime() + (ttl or CONTEXT_TTL),
		item = extra and extra.item or nil,
		deposit = extra and extra.deposit or nil,
		proceeds = extra and extra.proceeds or nil,
		skill = extra and extra.skill or nil,
	}
end

local function ConsumeContext()
	if not pending then
		return nil
	end
	if GetTime() > pending.expires then
		pending = nil
		return nil
	end
	local context = pending
	pending = nil
	return context
end

local function LootRecent()
	if lootOpen then
		return true
	end
	return lootClosedAt > 0 and (GetTime() - lootClosedAt) < 1.5
end

local function FrameShown(name)
	local frame = _G[name]
	return frame and frame.IsShown and frame:IsShown()
end

local function RepairCursor()
	if type(InRepairMode) ~= "function" then
		return false
	end
	local ok, mode = pcall(InRepairMode)
	return ok and mode and mode ~= 0 and mode ~= false
end

local function NoteRepairQuote()
	if type(GetRepairAllCost) ~= "function" then
		return
	end
	local ok, cost = pcall(GetRepairAllCost)
	cost = ok and ZGT.AsNumber(cost) or nil
	if cost and cost > 0 then
		repairQuote = cost
	end
end

local function RepairPaid(delta)
	if not repairQuote or delta >= 0 or math.abs(delta) ~= repairQuote then
		return false
	end
	if type(GetRepairAllCost) == "function" then
		local ok, cost = pcall(GetRepairAllCost)
		cost = ok and ZGT.AsNumber(cost) or nil
		if cost and cost >= repairQuote then
			return false
		end
	end
	repairQuote = nil
	return true
end

local function Classify(delta)
	local context = ConsumeContext()
	if context and context.source then
		return context.source, context
	end
	if delta < 0 and RepairCursor() then
		return "repairs"
	end
	if RepairPaid(delta) then
		return "repairs"
	end
	if FrameShown("MerchantFrame") then
		return delta >= 0 and "vendor" or "vendorBuy"
	end
	if delta < 0 and (FrameShown("AuctionHouseFrame") or FrameShown("AuctionFrame")) then
		return "auctionBuy"
	end
	if FrameShown("ClassTrainerFrame") or FrameShown("TrainerFrame") then
		return delta < 0 and "training" or "other"
	end
	if FrameShown("TaxiFrame") or FrameShown("FlightMapFrame") then
		return delta < 0 and "flight" or "other"
	end
	if FrameShown("TradeFrame") then
		return delta >= 0 and "other" or "spent"
	end
	if FrameShown("MailFrame") then
		return delta >= 0 and "other" or "spent"
	end
	if delta > 0 and LootRecent() then
		return "loot"
	end
	return delta >= 0 and "other" or "spent"
end

local function AddLog(day, item, copper)
	local log = day.auctionsLog
	log[#log + 1] = {
		item = item or "Auction sale",
		copper = copper,
		clock = date("%H:%M"),
		stamp = time(),
	}
	while #log > AUCTION_LOG_CAP do
		table.remove(log, 1)
	end
end

local lossChatAt = 0

local function SkipToken(message, index)
	local code = message:sub(index + 1, index + 1)
	if code == "c" then
		return index + 10
	end
	if code == "T" then
		local finish = message:find("|t", index + 2, true)
		return finish and (finish + 2) or (#message + 1)
	end
	if code == "H" then
		local finish = message:find("|h", index + 2, true)
		return finish and (finish + 2) or (#message + 1)
	end
	return index + 2
end

local function FirstAmountIndex(message)
	local index = 1
	while index <= #message do
		if message:byte(index) == 124 then
			index = SkipToken(message, index)
		elseif message:sub(index, index):match("%d") then
			return index
		else
			index = index + 1
		end
	end
	return nil
end

local function AmountIsNegative(message)
	local index = FirstAmountIndex(message)
	if not index then
		return false
	end
	local previous = index - 1
	while previous > 0 and message:sub(previous, previous):match("%s") do
		previous = previous - 1
	end
	return previous > 0 and message:sub(previous, previous) == "-"
end

local function PrefixAmount(message)
	local index = FirstAmountIndex(message)
	if not index then
		return "-" .. message
	end
	return message:sub(1, index - 1) .. "-" .. message:sub(index)
end

local function PurseDown()
	if type(GetMoney) ~= "function" or lastMoney == nil then
		return false
	end
	local money = ZGT.AsNumber(GetMoney())
	return money ~= nil and money < lastMoney
end

local function NamedLoss(message)
	local plain = ZGT.StripMarkup(message):lower()
	return plain:find("spent", 1, true)
		or plain:find("spend", 1, true)
		or plain:find("paid", 1, true)
		or plain:find("you lose", 1, true)
		or plain:find("you lost", 1, true)
		or plain:find("you pay", 1, true)
end

local function FilterSpentGold(_, event, message, ...)
	if not ZGT.IsReadable(message) or type(message) ~= "string" then
		return false
	end
	if ZGT.IsIncomeMoneyMessage(message) or not ZGT.ParseMoneyString(message) then
		return false
	end
	local loss = NamedLoss(message) or (event == "CHAT_MSG_MONEY" and PurseDown())
	if not loss then
		return false
	end
	lossChatAt = GetTime()
	if AmountIsNegative(message) then
		return false
	end
	return false, PrefixAmount(message), ...
end

local chatFilterOn = false

local function InstallChatFilter()
	if chatFilterOn or type(ChatFrame_AddMessageEventFilter) ~= "function" then
		return
	end
	chatFilterOn = true
	ChatFrame_AddMessageEventFilter("CHAT_MSG_MONEY", FilterSpentGold)
	ChatFrame_AddMessageEventFilter("CHAT_MSG_SYSTEM", FilterSpentGold)
end

local function ChatLine(text)
	if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
		DEFAULT_CHAT_FRAME:AddMessage(text)
		return
	end
	print(text)
end

local function AnnounceSpend(amount, source, skill)
	local label = skill and (ZGT.TrainingGroup(skill) .. " training") or SPEND_LABEL[source] or "Spent"
	local text = "-" .. ZGT.FormatMoney(amount) .. "  |cff9e9ea6" .. label .. "|r"
	local function emit()
		if GetTime() - lossChatAt < 1 then
			return
		end
		lossChatAt = GetTime()
		ChatLine(text)
	end
	if C_Timer and C_Timer.After then
		C_Timer.After(0.35, emit)
	else
		emit()
	end
end

local function MatchedRefund(delta, extra)
	local refund = extra and extra.deposit
	local proceeds = extra and extra.proceeds
	if type(refund) ~= "number" or type(proceeds) ~= "number" then
		return nil
	end
	if refund <= 0 or proceeds < 0 or delta <= 0 then
		return nil
	end
	if proceeds + refund ~= delta then
		return nil
	end
	return refund
end

local function RecordDelta(delta)
	if not characterKey or not ZGT.DB or delta == 0 then
		return
	end
	local source, extra = Classify(delta)
	local day = DayBucket(characterKey, TodayKey())
	-- The purse change is the source of truth. Gains go to an income bucket.
	-- Losses go to the spend bucket that was open when the gold left.
	-- A seller invoice that adds up to this gain returns the listing deposit
	-- inside the same copper. That part goes back onto deposit, and the sale
	-- keeps bid minus the house cut.
	local auctionCopper
	if delta < 0 then
		if not SPEND_SET[source] then
			source = "spent"
		end
		local amount = math.abs(delta)
		day[source] = day[source] + amount
		local skill
		if source == "training" and extra and type(extra.skill) == "string" and extra.skill ~= "" then
			skill = extra.skill
			day.trainingBy[skill] = (day.trainingBy[skill] or 0) + amount
		end
		AnnounceSpend(amount, source, skill)
	elseif source == "auctions" then
		local refund = MatchedRefund(delta, extra)
		if refund then
			day.deposit = day.deposit - refund
			auctionCopper = delta - refund
		else
			auctionCopper = delta
		end
		if auctionCopper > 0 then
			day.auctions = day.auctions + auctionCopper
		end
	elseif source == "loot" or source == "vendor" or source == "quests" or source == "other" then
		day[source] = day[source] + delta
	else
		day.other = day.other + delta
	end
	if auctionCopper and auctionCopper > 0 then
		local item = extra and extra.item
		if not ZGT.IsReadable(item) or type(item) ~= "string" or item == "" then
			item = "Auction sale"
		end
		AddLog(day, item, auctionCopper)
	end
	if type(ZGT.DB.session) == "table" then
		ZGT.DB.session.net = (ZGT.DB.session.net or 0) + delta
	end
	ZGT.Notify()
end

local function SnapshotMoney()
	local money = ZGT.AsNumber(GetMoney())
	if money == nil then
		return
	end
	if lastMoney == nil then
		lastMoney = money
		return
	end
	local delta = money - lastMoney
	if delta == 0 or not characterKey or not ZGT.DB then
		return
	end
	lastMoney = money
	RecordDelta(delta)
end

local function OnMoneyChat(text)
	if not ZGT.IsReadable(text) or type(text) ~= "string" then
		if LootRecent() then
			SetContext("loot")
		end
		return
	end
	local parsed = ZGT.ParseMoneyString(text)
	if ZGT.IsLootMoneyMessage(text) and (parsed == nil or parsed > 0) then
		SetContext("loot")
		return
	end
	if pending and GetTime() <= pending.expires and pending.source and pending.source ~= "other" then
		return
	end
	if RepairCursor() or FrameShown("MerchantFrame") or FrameShown("AuctionHouseFrame") or FrameShown("AuctionFrame") or FrameShown("TaxiFrame") or FrameShown("FlightMapFrame") or FrameShown("ClassTrainerFrame") or FrameShown("TrainerFrame") or FrameShown("TradeFrame") or FrameShown("MailFrame") then
		return
	end
	SetContext("other")
end

local function SetMailContext(index)
	local source = "other"
	local item
	local deposit
	local proceeds
	if type(GetInboxInvoiceInfo) == "function" then
		local ok, invoiceType, itemName, _, bid, buyout, invoiceDeposit, consignment = pcall(GetInboxInvoiceInfo, index)
		if ok and ZGT.IsReadable(invoiceType) and invoiceType == "seller" then
			local bidAmount = ZGT.AsNumber(bid) or 0
			local buyoutAmount = ZGT.AsNumber(buyout) or 0
			if bidAmount > 0 or buyoutAmount > 0 then
				source = "auctions"
				if ZGT.IsReadable(itemName) and type(itemName) == "string" and itemName ~= "" then
					item = ZGT.StripMarkup(itemName)
				else
					item = "Auction sale"
				end
				local refund = ZGT.AsNumber(invoiceDeposit)
				local cut = ZGT.AsNumber(consignment)
				local price = ZGT.AsNumber(bid)
				if refund and cut and price and refund > 0 and cut >= 0 and price >= cut then
					deposit = refund
					proceeds = price - cut
				end
			end
		end
	end
	SetContext(source, { item = item, deposit = deposit, proceeds = proceeds }, MAIL_TTL)
end

local function InstallWrap(name, applicator)
	local current = _G[name]
	if type(current) ~= "function" or wrapped[current] then
		return
	end
	wrapped[current] = true
	if type(hooksecurefunc) == "function" then
		hooksecurefunc(name, function(...)
			pcall(applicator, ...)
		end)
	end
	local original = current
	local function wrapper(...)
		pcall(applicator, ...)
		return original(...)
	end
	wrapped[wrapper] = true
	_G[name] = wrapper
end

local function MarkSpend(source, ttl)
	SetContext(source, nil, ttl or 3)
end

local function HookSecure(owner, name, applicator)
	if type(owner) ~= "table" or type(owner[name]) ~= "function" or type(hooksecurefunc) ~= "function" then
		return
	end
	local current = owner[name]
	if wrapped[current] then
		return
	end
	wrapped[current] = true
	hooksecurefunc(owner, name, function(...)
		pcall(applicator, ...)
	end)
end

local function InstallHooks()
	InstallWrap("TakeInboxMoney", SetMailContext)
	InstallWrap("TakeTaxiNode", function()
		MarkSpend("flight", 4)
	end)
	InstallWrap("RepairAllItems", function()
		MarkSpend("repairs", 3)
	end)
	InstallWrap("BuyMerchantItem", function()
		MarkSpend("vendorBuy", 3)
	end)
	InstallWrap("BuybackItem", function()
		MarkSpend("vendorBuy", 3)
	end)
	InstallWrap("BuyTrainerService", function(index)
		-- The skill line names what was bought: "Cooking", "Riding", or the
		-- class spec for class spells. A missing or secret value still records
		-- the total under `training`, with no skill label.
		local skill
		if type(GetTrainerServiceSkillLine) == "function" then
			local ok, line = pcall(GetTrainerServiceSkillLine, index)
			if ok and ZGT.IsReadable(line) and type(line) == "string" and line ~= "" then
				skill = line
			end
		end
		SetContext("training", { skill = skill }, 4)
	end)
	InstallWrap("PlaceAuctionBid", function()
		MarkSpend("auctionBuy", 5)
	end)
	InstallWrap("StartAuction", function()
		MarkSpend("deposit", 5)
	end)
	if type(C_TaxiMap) == "table" then
		HookSecure(C_TaxiMap, "TakeTaxiNode", function()
			MarkSpend("flight", 4)
		end)
	end
	if type(C_AuctionHouse) == "table" then
		local function markBuy()
			MarkSpend("auctionBuy", 5)
		end
		local function markDeposit()
			MarkSpend("deposit", 5)
		end
		HookSecure(C_AuctionHouse, "PlaceBid", markBuy)
		HookSecure(C_AuctionHouse, "StartCommoditiesPurchase", markBuy)
		HookSecure(C_AuctionHouse, "ConfirmCommoditiesPurchase", markBuy)
		HookSecure(C_AuctionHouse, "ConfirmPostItem", markDeposit)
		HookSecure(C_AuctionHouse, "ConfirmPostCommodity", markDeposit)
		HookSecure(C_AuctionHouse, "PostItem", markDeposit)
		HookSecure(C_AuctionHouse, "PostCommodity", markDeposit)
	end
end

local function AddPlayed(seconds)
	if not characterKey or not ZGT.DB then
		return
	end
	local day = DayBucket(characterKey, TodayKey())
	day.played = day.played + seconds
	if type(ZGT.DB.session) == "table" then
		ZGT.DB.session.played = (ZGT.DB.session.played or 0) + seconds
	end
end

local function FlushPlayed(shouldNotify)
	local seconds = elapsed
	elapsed = 0
	if seconds <= 0 or not inWorld then
		return
	end
	AddPlayed(seconds)
	if shouldNotify then
		ZGT.Notify()
	end
end

local function TryEnterWorld(isInitialLogin)
	local key, named = ResolveCharacterKey()
	if not key then
		return false
	end
	characterKey = key
	if named then
		CoalesceCharacters(key)
	end
	if not entered then
		entered = true
		if isInitialLogin or type(ZGT.DB.session) ~= "table" then
			ZGT.DB.session = { net = 0, played = 0 }
		else
			NormalizeSession(ZGT.DB.session)
		end
	end
	inWorld = true
	SnapshotMoney()
	ZGT.Notify()
	return true
end

local function ScheduleEnter(isInitialLogin)
	local generation = worldGen
	local function attempt(remaining)
		if worldGen ~= generation then
			return
		end
		if TryEnterWorld(isInitialLogin) or remaining <= 0 then
			return
		end
		if C_Timer and C_Timer.After then
			C_Timer.After(1, function()
				attempt(remaining - 1)
			end)
		end
	end
	attempt(10)
end

function ZGT.PointValid(point)
	return type(point) == "string" and POINTS[point]
end

eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("PLAYER_LEAVING_WORLD")
eventFrame:RegisterEvent("PLAYER_LOGOUT")
eventFrame:RegisterEvent("PLAYER_MONEY")
eventFrame:RegisterEvent("CHAT_MSG_MONEY")
eventFrame:RegisterEvent("QUEST_TURNED_IN")
eventFrame:RegisterEvent("LOOT_OPENED")
eventFrame:RegisterEvent("LOOT_CLOSED")
eventFrame:RegisterEvent("MAIL_SHOW")
eventFrame:RegisterEvent("TAXIMAP_OPENED")
eventFrame:RegisterEvent("TRAINER_SHOW")
pcall(eventFrame.RegisterEvent, eventFrame, "AUCTION_HOUSE_SHOW")
pcall(eventFrame.RegisterEvent, eventFrame, "MERCHANT_SHOW")
pcall(eventFrame.RegisterEvent, eventFrame, "MERCHANT_UPDATE")
pcall(eventFrame.RegisterEvent, eventFrame, "MERCHANT_CLOSED")

eventFrame:SetScript("OnEvent", function(_, event, ...)
	if event == "ADDON_LOADED" then
		if ... ~= ADDON_NAME then
			return
		end
		InitDB()
		InstallHooks()
		InstallChatFilter()
		eventFrame:UnregisterEvent("ADDON_LOADED")
	elseif event == "PLAYER_ENTERING_WORLD" then
		local isInitialLogin = ...
		if not ZGT.IsReadable(isInitialLogin) then
			isInitialLogin = false
		end
		InstallChatFilter()
		ScheduleEnter(isInitialLogin and true or false)
	elseif event == "PLAYER_LEAVING_WORLD" then
		FlushPlayed(true)
		inWorld = false
		worldGen = worldGen + 1
	elseif event == "PLAYER_LOGOUT" then
		FlushPlayed(false)
	elseif event == "PLAYER_MONEY" then
		SnapshotMoney()
	elseif event == "CHAT_MSG_MONEY" then
		pcall(OnMoneyChat, ...)
	elseif event == "QUEST_TURNED_IN" then
		local _, _, money = ...
		local copper = ZGT.AsNumber(money)
		if copper and copper > 0 then
			SetContext("quests")
		end
	elseif event == "LOOT_OPENED" then
		lootOpen = true
	elseif event == "LOOT_CLOSED" then
		lootOpen = false
		lootClosedAt = GetTime()
	elseif event == "MAIL_SHOW" or event == "TAXIMAP_OPENED" or event == "TRAINER_SHOW" or event == "AUCTION_HOUSE_SHOW" or event == "MERCHANT_SHOW" then
		if event == "MERCHANT_SHOW" then
			NoteRepairQuote()
		end
		InstallHooks()
	elseif event == "MERCHANT_UPDATE" then
		NoteRepairQuote()
	elseif event == "MERCHANT_CLOSED" then
		repairQuote = nil
	end
end)

eventFrame:SetScript("OnUpdate", function(_, delta)
	if not inWorld then
		return
	end
	elapsed = elapsed + delta
	if elapsed >= PLAYED_INTERVAL then
		FlushPlayed(true)
	end
end)
