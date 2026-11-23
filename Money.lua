ZoraGoldTracker = ZoraGoldTracker or {}
local ZGT = ZoraGoldTracker

ZGT.COLOR = {
	up = { 0.243, 0.878, 0.478 },
	down = { 0.937, 0.251, 0.200 },
	flat = { 0.902, 0.902, 0.922 },
	muted = { 0.62, 0.62, 0.66 },
	text = { 0.93, 0.93, 0.95 },
	loot = { 0.855, 0.702, 0.200 },
	auctions = { 0.349, 0.620, 0.980 },
	vendor = { 0.949, 0.549, 0.200 },
	quests = { 0.620, 0.780, 0.550 },
	other = { 0.700, 0.700, 0.740 },
	auctionBuy = { 0.640, 0.460, 0.920 },
	deposit = { 0.820, 0.660, 0.360 },
	flight = { 0.350, 0.780, 0.820 },
	repairs = { 0.800, 0.620, 0.400 },
	vendorBuy = { 0.900, 0.400, 0.620 },
	training = { 0.670, 0.800, 0.340 },
	spent = { 0.900, 0.350, 0.320 },
}

-- Weapon skill lines the trainer reports (English names, lowercased for
-- matching). Other locales have no entry, so their lines stay separate.
local WEAPON_SKILLS = {}
for _, name in ipairs({
	"Axes", "Two-Handed Axes", "Bows", "Crossbows", "Daggers", "Fist Weapons",
	"Guns", "Maces", "Two-Handed Maces", "Polearms", "Staves", "Swords",
	"Two-Handed Swords", "Thrown", "Wands", "Unarmed",
}) do
	WEAPON_SKILLS[name:lower()] = true
end

-- Display name for a trainer skill line. The raw name is still what gets
-- stored; this only changes how it is shown.
function ZGT.TrainingGroup(skill)
	if type(skill) ~= "string" or skill == "" then
		return "Other"
	end
	if WEAPON_SKILLS[skill:lower()] then
		return "Weapon"
	end
	return skill
end

local GOLD_ICON = "|TInterface\\MoneyFrame\\UI-GoldIcon:12:12:2:0|t"
local SILVER_ICON = "|TInterface\\MoneyFrame\\UI-SilverIcon:12:12:2:0|t"
local COPPER_ICON = "|TInterface\\MoneyFrame\\UI-CopperIcon:12:12:2:0|t"

local lootPatterns

local function IsSecret(value)
	if type(issecretvalue) ~= "function" then
		return false
	end
	local ok, secret = pcall(issecretvalue, value)
	return not ok or secret
end

function ZGT.IsReadable(value)
	if value == nil then
		return false
	end
	return not IsSecret(value)
end

function ZGT.AsNumber(value)
	if value == nil or IsSecret(value) then
		return nil
	end
	local ok, number = pcall(tonumber, value)
	if not ok or type(number) ~= "number" then
		return nil
	end
	if number ~= number or number == math.huge or number == -math.huge then
		return nil
	end
	return number
end

function ZGT.StripMarkup(text)
	if type(text) ~= "string" then
		return ""
	end
	text = text:gsub("|c%x%x%x%x%x%x%x%x", "")
	text = text:gsub("|r", "")
	return text
end

function ZGT.Paint(texture, color, alpha)
	texture:SetColorTexture(color[1], color[2], color[3], alpha or 1)
end

function ZGT.ApplyBackdrop(frame, alpha)
	if not frame.SetBackdrop then
		return
	end
	local ok = pcall(frame.SetBackdrop, frame, {
		bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = true,
		tileSize = 16,
		edgeSize = 12,
		insets = { left = 3, right = 3, top = 3, bottom = 3 },
	})
	if not ok then
		return
	end
	frame:SetBackdropColor(0.04, 0.045, 0.06, alpha or 0.94)
	frame:SetBackdropBorderColor(0.78, 0.62, 0.22, 0.95)
end

local function UnitPattern(globalString)
	if type(globalString) ~= "string" then
		return nil
	end
	local pattern = globalString:gsub("([%(%)%.%+%-%*%?%[%]%^%$])", "%%%1")
	pattern = pattern:gsub("%%d", "(%%d+)")
	pattern = pattern:gsub("%%s", ".+")
	if not pattern:find("%(", 1, true) then
		return nil
	end
	return pattern
end

local function MessagePattern(globalString)
	if type(globalString) ~= "string" then
		return nil
	end
	local pattern = globalString:gsub("([%(%)%.%+%-%*%?%[%]%^%$])", "%%%1")
	pattern = pattern:gsub("%%s", ".+")
	pattern = pattern:gsub("%%d", "%%d+")
	return pattern
end

local function FirstCapture(text, pattern)
	if not pattern then
		return nil
	end
	local ok, value = pcall(string.match, text, pattern)
	if not ok then
		return nil
	end
	return tonumber(value)
end

local function ParseWords(text)
	local gold = FirstCapture(text, UnitPattern(GOLD_AMOUNT))
	local silver = FirstCapture(text, UnitPattern(SILVER_AMOUNT))
	local copper = FirstCapture(text, UnitPattern(COPPER_AMOUNT))
	if not gold and not silver and not copper then
		return nil
	end
	return (gold or 0) * 10000 + (silver or 0) * 100 + (copper or 0)
end

local function ParseIcons(text)
	local gold = tonumber(text:match("(%d+)%s*|T[^|]-UI%-GoldIcon") or "")
	local silver = tonumber(text:match("(%d+)%s*|T[^|]-UI%-SilverIcon") or "")
	local copper = tonumber(text:match("(%d+)%s*|T[^|]-UI%-CopperIcon") or "")
	if not gold and not silver and not copper then
		return nil
	end
	return (gold or 0) * 10000 + (silver or 0) * 100 + (copper or 0)
end

function ZGT.ParseMoneyString(text)
	if not ZGT.IsReadable(text) or type(text) ~= "string" then
		return nil
	end
	local words = ParseWords(text)
	if words then
		return words
	end
	return ParseIcons(text)
end

local function LootPatterns()
	if lootPatterns then
		return lootPatterns
	end
	lootPatterns = {}
	local seen = {}
	for _, name in ipairs({ "LOOT_MONEY", "LOOT_MONEY_SPLIT", "YOU_LOOT_MONEY" }) do
		local pattern = MessagePattern(_G[name])
		if pattern and not seen[pattern] then
			seen[pattern] = true
			lootPatterns[#lootPatterns + 1] = pattern
		end
	end
	return lootPatterns
end

function ZGT.IsLootMoneyMessage(text)
	if not ZGT.IsReadable(text) or type(text) ~= "string" then
		return false
	end
	local plain = ZGT.StripMarkup(text)
	for _, pattern in ipairs(LootPatterns()) do
		local ok, found = pcall(string.find, plain, pattern)
		if ok and found then
			return true
		end
	end
	return false
end

function ZGT.IsIncomeMoneyMessage(text)
	if ZGT.IsLootMoneyMessage(text) then
		return true
	end
	if not ZGT.IsReadable(text) or type(text) ~= "string" then
		return false
	end
	local plain = ZGT.StripMarkup(text)
	for _, name in ipairs({ "LOOT_MONEY_REFUND", "ERR_QUEST_REWARD_MONEY_S" }) do
		local pattern = MessagePattern(_G[name])
		if pattern then
			local ok, found = pcall(string.find, plain, pattern)
			if ok and found then
				return true
			end
		end
	end
	return false
end

function ZGT.FormatMoney(copper, withSign)
	copper = ZGT.AsNumber(copper)
	if not copper then
		return "—"
	end
	local negative = copper < 0
	local positive = copper > 0
	copper = math.floor(math.abs(copper) + 0.5)
	local gold = math.floor(copper / 10000)
	local silver = math.floor(copper / 100) % 100
	local coins = copper % 100
	local parts = {}
	if gold > 0 then
		parts[#parts + 1] = gold .. GOLD_ICON
	end
	if silver > 0 or gold > 0 then
		parts[#parts + 1] = silver .. SILVER_ICON
	end
	parts[#parts + 1] = coins .. COPPER_ICON
	local text = table.concat(parts, " ")
	if negative then
		return "-" .. text
	end
	if withSign and positive then
		return "+" .. text
	end
	return text
end

function ZGT.FormatRate(copperPerHour)
	copperPerHour = ZGT.AsNumber(copperPerHour)
	if not copperPerHour then
		return "—"
	end
	local sign = ""
	if copperPerHour > 0 then
		sign = "+"
	elseif copperPerHour < 0 then
		sign = "-"
	end
	local absCopper = math.abs(copperPerHour)
	local gold = absCopper / 10000
	if gold >= 1 then
		if gold >= 100 then
			return string.format("%s%dg/hr", sign, math.floor(gold + 0.5))
		end
		return string.format("%s%.1fg/hr", sign, gold)
	end
	local silver = absCopper / 100
	if silver >= 99.5 then
		return string.format("%s%.1fg/hr", sign, gold)
	end
	if silver >= 10 then
		return string.format("%s%.0fs/hr", sign, silver)
	end
	if silver >= 0.1 then
		return string.format("%s%.1fs/hr", sign, silver)
	end
	return string.format("%s%dc/hr", sign, math.floor(absCopper + 0.5))
end

function ZGT.FormatCompact(copper)
	copper = ZGT.AsNumber(copper) or 0
	local sign = ""
	if copper > 0 then
		sign = "+"
	elseif copper < 0 then
		sign = "-"
	end
	local gold = math.abs(copper) / 10000
	if gold >= 100 then
		return string.format("%s%dg", sign, math.floor(gold + 0.5))
	end
	if gold >= 1 then
		return string.format("%s%.1fg", sign, gold)
	end
	if math.abs(copper) >= 100 then
		return string.format("%s%.0fs", sign, math.abs(copper) / 100)
	end
	return string.format("%s%dc", sign, math.floor(math.abs(copper) + 0.5))
end

function ZGT.FormatPercent(percent)
	percent = ZGT.AsNumber(percent)
	if not percent then
		return nil
	end
	if percent > 999 then
		percent = 999
	elseif percent < -999 then
		percent = -999
	end
	local shown = math.floor(math.abs(percent) + 0.5)
	if shown == 0 and percent ~= 0 then
		shown = 1
	end
	if shown == 0 then
		return "0%"
	end
	if percent > 0 then
		return "+" .. shown .. "%"
	end
	return "-" .. shown .. "%"
end

function ZGT.FormatPlayed(seconds)
	seconds = math.floor(ZGT.AsNumber(seconds) or 0)
	if seconds < 0 then
		seconds = 0
	end
	local hours = math.floor(seconds / 3600)
	local minutes = math.floor(seconds / 60) % 60
	local secs = seconds % 60
	if hours > 0 then
		return string.format("%dh %dm", hours, minutes)
	end
	if minutes > 0 then
		return string.format("%dm %ds", minutes, secs)
	end
	return string.format("%ds", secs)
end

function ZGT.ColorHex(color)
	local function channel(value)
		local byte = math.floor((value or 0) * 255 + 0.5)
		if byte < 0 then
			byte = 0
		elseif byte > 255 then
			byte = 255
		end
		return string.format("%02x", byte)
	end
	return channel(color[1]) .. channel(color[2]) .. channel(color[3])
end
