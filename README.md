# Zora Gold Tracker

Account-wide gold per hour for WoW. The purse is the source of truth: every change to `GetMoney()` is stored on the character who was logged in, then the ticker and the ledger add those days up.

There are no classes. Each file adds functions to one shared table, `ZoraGoldTracker` (`ZGT`). Load order is fixed by `ZoraGoldTracker.toc`:

1. `Money.lua` — colors, number safety, chat parsing, text formatting
2. `Core.lua` — saved data, recording, queries
3. `Ticker.lua` — the always-on gold-per-hour bar
4. `Detail.lua` — the ledger window
5. `Sales.lua` — the auction sales list

`Core.lua` finishes `InitDB` on `ADDON_LOADED` before the other files attach listeners. Keep that file order. `Detail.lua` calls `ZGT.RetentionDays()` while it is building frames, and `Ticker.lua` calls `ZGT.ToggleDetail` only after checking that it exists.

## Saved data

`ZoraGoldTrackerDB` is the SavedVariables table.

- `characters[Name-Surname].days["YYYY-MM-DD"]` holds one day. Forever's `UnitFullName` / `UnitName` return the first name and the surname; the surname is the key, not `GetRealmName()`. On login, older `Name-Realm` and `Name-Unknown` rows fold into the surname key only when no other surname key uses the same first name. Old rows cannot say which surname they belonged to, so if two characters share a first name, those old rows stay separate instead of being guessed.
- A day stores income and spending as copper counts: `loot`, `auctions`, `vendor`, `quests`, `other`, `auctionBuy`, `deposit`, `flight`, `repairs`, `vendorBuy`, `training`, `spent`, plus `played` seconds, `auctionsLog`, and `trainingBy`. `training` is the total trainer spend. `trainingBy` splits it by skill line (`{ Cooking = 1200, ["Feral Combat"] = 5000 }`) and never feeds `ZGT.Net`. Training bought before the split existed, or with no readable skill line, is in `training` only, and the ledger shows the gap as "Other". Every field stays at or above zero except `deposit`. `deposit` is the net listing fee: posts add to it, and a returned deposit on a collected sale subtracts from it, so a day that got more back than it posted goes negative.
- `session` is `{ net, played }` for the current login. A UI reload keeps it. A fresh login replaces it.
- `settings` stores ticker lock, scale, hidden state, and the screen points for the ticker and the ledger.

Date keys are `YYYY-MM-DD` strings. String order matches calendar order only while that format stays intact. `ZGT.DateOffset` moves by calendar day at 12:00, so a daylight-saving change does not skip a day. `ZGT.SpanDays` walks one day at a time for the same reason.

`RETENTION_DAYS` is 90. `Prune` runs from `InitDB` and deletes any day older than `ZGT.RetentionStart()` (today and the previous 89 days stay). All, Range, and the ledger chart all read that same cutoff. Raising the constant keeps more history from that login onward. It does not bring back days already deleted.

## Money.lua

Shared display and parsing. Nothing here writes the database.

`ZGT.COLOR` is the palette for income, spending, and up/down/flat. `ZGT.Paint` and `ZGT.ApplyBackdrop` are the only frame-drawing helpers.

`ZGT.AsNumber` and `ZGT.IsReadable` are the gate for every value that came from the game. Current clients can hand back secret values that error or taint if you touch them. `AsNumber` returns `nil` for secrets, non-numbers, and NaN/infinity. New game reads go through it.

`ZGT.ParseMoneyString` reads a chat line as copper. It tries localized `GOLD_AMOUNT` / `SILVER_AMOUNT` / `COPPER_AMOUNT` first, then gold/silver/copper icon textures. `ZGT.IsLootMoneyMessage` and `ZGT.IsIncomeMoneyMessage` match global strings (`LOOT_MONEY`, quest reward, refund), not English sentences.

`ZGT.FormatMoney` prints coin icons. `ZGT.FormatRate` and `ZGT.FormatCompact` print plain text for the ticker, where icons do not fit. `ZGT.GoldPerHour` lives in Core; these formatters only display the number they are given.

## Core.lua

Recording and queries. The UI never writes day buckets itself.

### What a view is

`ZGT.Net` is income minus spending. Spending fields other than `deposit` are stored positive, so a repair of 1g is `repairs = 10000`, not `-10000`. `deposit` is that same positive cost, then reduced by refunds, and `ZGT.Net` still just subtracts the field. A negative `deposit` therefore adds gold.

`ZGT.GetView(dateKey, scope)` is one day.

- `scope == "character"` totals the logged-in character.
- Any other scope totals the whole account.
- `view.characters` is still every character who has that day, sorted by net. The character list in the ledger uses this for both scopes.

`ZGT.GetRangeView(startKey, endKey, scope)` sums inclusive days the same way. `view.auctionCount` is the real sale count. `view.auctionsLog` is then cut to `AUCTION_LOG_CAP` (50), newest stamp first. The ledger only draws two of those rows.

`ZGT.GetComparison` is today versus the previous day. The ticker depends on `today`, `todayRate`, `percent`, and `direction`. `ZGT.GetRangeComparison` compares a span with the previous span of equal length. If that previous span starts before `RetentionStart`, `percent` is omitted so a partial window is not treated as a full one.

`ZGT.GoldPerHour` returns `nil` when `played` is under `ZGT.MIN_RATE_SECONDS` (60). Callers have to show an em dash for that nil. A rate is net copper divided by played hours, never by calendar hours.

`NormalizeDay` fills missing fields with `0` on the stored table. A read can write defaults into SavedVariables. Leave stored numbers as numbers.

### How gold is classified

`PLAYER_MONEY` calls `SnapshotMoney`. The first snapshot only remembers the purse. Later snapshots record `GetMoney() - lastMoney` through `RecordDelta`.

`RecordDelta` asks `Classify` what the change was, then:

- A loss always goes to a spend field. If `Classify` returned an income name, the loss is forced to `spent`.
- A gain goes to `loot`, `auctions`, `vendor`, `quests`, or `other`. Any other name is forced to `other`.
- An auction gain appends `auctionsLog` (capped at 50 per day, oldest removed). The logged copper is the sale after a matched deposit refund is removed.
- When a `"seller"` invoice's `bid - consignment + deposit` equals that purse gain, `deposit` on the invoice is subtracted from the day's `deposit` and only `bid - consignment` is added to `auctions`. A `"seller_temp_invoice"` is skipped, because that mail has no money attached yet. If the invoice numbers are missing or do not add up to the purse gain, the whole gain stays in `auctions` and `deposit` is left alone.
- The session net moves by the full purse delta, and listeners refresh.

`Classify` consumes a one-shot context if one is still inside its TTL. Contexts are set just before the purse moves:

| Source | How it gets set | TTL |
| --- | --- | --- |
| `quests` | `QUEST_TURNED_IN` with a money reward | 1.25s |
| `loot` | Loot window open, or still inside 1.5s after it closes, or a loot chat line | 1.25s |
| `auctions` | `"seller"` invoice while taking inbox money. The pending `"seller_temp_invoice"` is not used | 5s |
| `deposit` | `StartAuction`, `PostItem`, `PostCommodity`, `ConfirmPostItem`, `ConfirmPostCommodity` | 5s |
| `flight`, `repairs`, `vendorBuy`, `training`, `auctionBuy` | Hooks around the purchase API. Bids and commodity buys stay `auctionBuy` | 3–5s |

`BuyTrainerService(index)` reads `GetTrainerServiceSkillLine(index)` and carries it on the context as `skill`. `RecordDelta` adds the loss to `training` and to `trainingBy[skill]`. Class trainers report the spec ("Feral Combat"), professions report the profession ("Cooking"), so class spending splits by spec. Weapon skill lines ("Staves", "Two-Handed Maces", "Maces") are stored as reported and shown as one "Weapon" line by `ZGT.TrainingGroup` in `Money.lua`. That list matches English names only. The trainer-frame fallback in `Classify` has no index, so it counts in `training` with no skill.
| `other` | A money chat line that no open window explains | 1.25s |

If the context expired, `Classify` sniffs open frames (`MerchantFrame`, auction house, trainer, taxi, trade, mail) and the repair cursor / repair-all quote. A loss with the auction house open becomes `auctionBuy`, which is where a listing lands when its 5 second post context has already expired. Whatever is left becomes `loot` (recent loot window), `other` (gain), or `spent` (loss).

`InstallWrap` both `hooksecurefunc`s the global and replaces it. The applicator therefore runs twice. `SetContext` is safe to repeat. Do not record gold inside those hooks. `InstallHooks` runs again when a merchant, mail, taxi, trainer, or auction window opens, so late-loaded Blizzard functions still get hooked. The `wrapped` table stops a second hook on the same function.

### Chat spend lines

WoW often prints a spend with no minus sign. `FilterSpentGold` on `CHAT_MSG_MONEY` and `CHAT_MSG_SYSTEM` inserts one in front of the first number, skipping `|c` colors, `|T` textures, and `|H` links. It returns `false` plus the new message so the line is replaced, not hidden. A message that already has a minus, or that parses as income, is left alone.

`AnnounceSpend` prints its own `"-1g  Repair"` line only when the client did not already print a loss in the last second (`lossChatAt`). The announce waits 0.35s so the filter can win the race. Change either delay and you get a missing line or two lines.

### Played time

`OnUpdate` adds frame time while `inWorld` is true and flushes into today's `played` every 5 seconds (`PLAYED_INTERVAL`). Leaving the world or logging out flushes immediately and bumps `worldGen`, which cancels the enter-world retry loop. Played time is what makes gold per hour exist. Dropping a flush loses up to one interval.

`ScheduleEnter` retries for about 10 seconds because the character name can still be `"Unknown"` on the first `PLAYER_ENTERING_WORLD`. The key waits for a real first name and surname. An empty realm is not stored as `"Unknown"`. Until `characterKey` exists, `SnapshotMoney` keeps the previous purse value, and the next successful snapshot records the whole gap as one change.

## Ticker.lua

The bar named `ZoraGoldTrackerTicker`. Left click toggles the ledger. Right click opens lock, reset, hide, and scale. The mouse wheel, and `/zgt scale`, change scale from 50% to 200% in 10% steps. A number above 3 is treated as a percent (`150` means 1.5).

`/zgt` and `/zoragold` show the ticker and toggle the ledger. `show`, `hide`, `lock`, `reset`, and `scale` only touch the ticker.

The headline is account `GetComparison` for today. The sparkline is the last 7 account nets (`SPARK_DAYS`), drawn by `UpdateSpark` inside `pcall`. The first failure is printed once so a spark error does not spam chat or stop the headline.

Position is saved under `settings.tickerPoint/RelPoint/X/Y`. `SetUserPlaced(false)` is required before `GetPoint` / `SetPoint`, or the client fights the saved position. `ZGT.PointValid` rejects anything outside the nine UI anchor names.

The ticker does not flash on gold changes. `RecordDelta` only updates the saved numbers and calls `ZGT.Notify()`, so the ticker redraws its text and sparkline without any color pulse.

## Detail.lua

The ledger frame `ZoraGoldTrackerDetail`. Opening it (`ZGT.ToggleDetail`, ticker left click, or `/zgt`) resets to Day mode on today. Escape closes it through `UISpecialFrames`.

Three modes share one period, `CurrentPeriod()`:

- **Day.** One date. Hovering a bar calls `SelectDate`. Arrows move one day. The chart keeps a stable 14-day window (`CHART_WINDOW`) and only slides that window when the selected day leaves it.
- **Range.** Starts as the 7 days ending on the day you were viewing (`RANGE_PRESET`). Click a bar to set the anchor, click another to set the other end. Arrows slide the whole span by one day and stop at today or at `RetentionStart`.
- **All.** `OldestStoredDate()` through today. Arrows do nothing. The button tooltip states the 90-day keep.

`RefreshDetail` picks the query:

- All uses `GetRangeView` and colors the headline by the sign of net.
- A multi-day range uses `GetRangeComparison` and colors by gold per hour versus the previous span (`"vs prior N days"`).
- A single day uses `GetComparison`, which is the same path the ticker uses (`"vs prior day"`).

`detail.refreshing` blocks a nested refresh. Hover selection bails out while a refresh is running.

The chart in Range and All draws one column per retained day (90). Columns are created once. `LayoutColumns` repositions them only when the count changes. Repositioning under the cursor fires `OnEnter` again, and Day mode would chase the mouse across the chart. Labels are parented to the chart frame, not the column, so hiding a column does not hide its caption. `LayoutColumns` clears that text for hidden columns.

The plot stacks loot, auction sales, and vendor sales only. Quests and other income are in the numbers and in the tooltip, and they are absent from the bars. Net markers are a separate series.

Account and Character change `detail.scope` only. The character block still lists up to four characters for either scope. Auction rows show two sales. Multi-day rows print the date from `entry.stamp`.

The scope line is anchored to the previous-day button, which is anchored to the date text, which is anchored to the next-day button. Pointing any of those back at the scope line creates an anchor cycle and the UI stops updating.

## Sales.lua

The window `ZoraGoldTrackerSales` lists every stored auction sale as a flat sequence: a day header (date, sale count, total), then that day's sales newest first, then the next older day. The "All sales" button on the ledger's "Auctions collected" row opens it (`ZGT.ToggleSales`).

The data comes from `ZGT.GetAuctionDays(scope)` in Core. It reads each character's `auctionsLog` for every day inside the retention window and never writes. It adds no new saved data, so history from before this window existed shows up as soon as it loads. Two limits come from `auctionsLog` itself: at most `AUCTION_LOG_CAP` (50) sales are kept per character per day, and a sale only has a row when `Classify` recognised it as an auction payout. A row stored after the deposit split is the sale proceeds (`bid` minus the house cut). Older rows still show the whole purse gain, deposit included.

The list is virtualized. `VISIBLE` row frames are reused, `offset` is how many flat rows are scrolled past, and a plain `Slider` plus the mouse wheel move `offset`. Do not create one frame per sale. `syncing` stops the slider from calling `SetOffset` while the code is the one moving it. The window has its own Account / Character toggle and starts from the ledger's current scope. It saves its own position under `settings.salesPoint/RelPoint/X/Y`, and it shares small helpers from `ZGT.UI`, which `Detail.lua` fills in before this file loads.

## Sections to be careful with

**Purse before category.** Amounts come from `GetMoney()` deltas. Chat lines, open frames, and hooks only name the bucket. Parsing a chat amount and also applying the purse delta double-counts.

**`Classify` order and TTLs.** The pending context is consumed once. A shorter TTL, or a `Classify` call that runs before the matching `PLAYER_MONEY`, drops the hint and the gold lands in `other` or `spent`. Mail uses 5 seconds because the purse moves after the inbox click.

**`RecordDelta` bucket rules.** Income fields stay positive. Spend fields other than `deposit` stay positive. `ZGT.Net` is the only subtraction. Writing a negative repair into `repairs` makes that repair add gold. A negative `deposit` is the refund credit and is meant to add gold. The refund is recorded on the day the sale mail is looted. Listings already stored under `auctionBuy` stay there. A cancel fee while the auction house is open still falls through to `auctionBuy`, because the deposit itself was charged at posting.

**`InstallWrap` runs the hook twice.** Keep applicators idempotent. `HookSecure` (used for `C_AuctionHouse` and `C_TaxiMap`) is post-hook only and runs once.

**`FilterSpentGold` and `SkipToken`.** A wrong skip over `|c`, `|T`, or `|H` puts the minus inside a color code or an item link. Returning `true` from the filter deletes the chat line. `lossChatAt` is shared by the filter and `AnnounceSpend`.

**`NormalizeDay` mutates saved days.** Query code that expects a pure read can still create missing zeros in the database.

**Date math stays on calendar keys.** Compare keys as strings. Step with `ZGT.DateOffset`. Count with `ZGT.SpanDays`. Dividing two `time()` stamps by 86400 drifts across daylight saving.

**Retention has one cutoff.** `Prune`, Range clamping, All, and the 90 chart columns all use `ZGT.RetentionStart` / `ZGT.RetentionDays`. A second hardcoded `90` or `-89` will disagree after the constant changes, and `Prune` will delete whatever falls outside its own cutoff on next login.

**`GetComparison` shape is the ticker contract.** Renaming `today`, `todayRate`, `percent`, or `direction` blanks the bar. Range totals go through `GetRangeView`. The ticker never follows the ledger's selected range.

**Played time is flushed, not sampled.** Stopping `OnUpdate`, or flushing while `inWorld` is false, freezes gold per hour. Session played and today's played are updated together in `AddPlayed`.

**Ledger hover and layout.** Day mode selects on `OnEnter`. Range mode selects on `OnMouseDown` and must not call `SelectDate` from hover. Avoid `ClearAllPoints` / `SetPoint` on chart columns during a hover refresh unless `chartLayoutCount` changed.

**Frame points.** Call `SetUserPlaced(false)` before reading or restoring a point, and reject anchors that fail `ZGT.PointValid`. The detail date row is one anchor chain. The ticker and the ledger store points under different setting prefixes (`ticker` and `detail`).
