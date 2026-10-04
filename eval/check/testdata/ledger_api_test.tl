--- The ledger task's hidden API test: eval/check/grade.tl runs it
--- against a copy of a solver's project, never shown to the solver.
local ledger = require("ledger")

local CSV <const> = table.concat({
  "when,amount,category,note",
  "2026-01-31T23:30:00-05:00,12.50,food,\"late dinner, downtown\"",
  "2026-02-01T10:00:00Z,-3.5,food,refund",
  "2026-02-15T12:00:00+01:00,1000,rent,\"multi",
  "line \"\"note\"\"\"",
  "not-a-date,5,food,bad",
  "2026-03-01T00:30:00+01:00,0.29,misc,",
  "2026-02-10T09:00:00Z,abc,food,bad amount",
  "2026-02-11T09:00:00Z,1.234,food,three places",
  "2026-02-12T09:00:00Z,-0.07,fees,",
}, "\n") .. "\n"

local function test_parse_reads_each_transaction_exactly()
  local parsed, why = ledger.parse(CSV)
  assert(parsed ~= nil, why)
  local txs: {ledger.Transaction} = parsed.transactions
  assert(#txs == 5, #txs .. " transactions")
  local first = txs[1]
  assert(first.line == 2, "line " .. tostring(first.line))
  assert(first.at == 1769920200, "at " .. tostring(first.at))
  assert(first.cents == 1250 and math.type(first.cents) == "integer", "cents " ..
      tostring(first.cents))
  assert(first.category == "food" and first.note == "late dinner, downtown", first.note)
  assert(txs[2].cents == -350, "-3.5 is " .. tostring(txs[2].cents))
  assert(txs[3].line == 4 and txs[3].note == "multi\nline \"note\"", "the multi-line record")
  assert(txs[3].cents == 100000, "1000 is " .. tostring(txs[3].cents))
  assert(txs[4].line == 7 and txs[4].cents == 29, "0.29 is " .. tostring(txs[4].cents))
  assert(txs[5].line == 10 and txs[5].cents == -7, "-0.07 is " .. tostring(txs[5].cents))
end

local function test_parse_names_each_record_it_skips()
  local parsed = assert(ledger.parse(CSV))
  local skipped: {ledger.Skip} = parsed.skipped
  local lines: {string} = {}
  for _, skip in ipairs(skipped) do
    assert(skip.reason ~= nil and skip.reason ~= "", "no reason for line " .. skip.line)
    lines[#lines + 1] = tostring(skip.line)
  end
  assert(table.concat(lines, ",") == "6,8,9", "skipped lines " .. table.concat(lines, ","))
end

local function test_parse_refuses_another_header()
  local parsed, why = ledger.parse("date,amount,category,note\n2026-01-01T00:00:00Z,1,a,\n")
  assert(parsed == nil and why ~= "", "a file with the wrong header was read")
end

local function tx(at: integer, cents: integer, category: string): ledger.Transaction
  return { line = 2, at = at, cents = cents, category = category, note = "" }
end

--- 2026-01-31T23:30:00-05:00, 2026-02-01T10:00:00Z and
--- 2026-03-01T00:30:00+01:00, as seconds.
local LATE_JANUARY <const> = 1769920200
local FEBRUARY <const> = 1769940000
local MARCH_IN_BERLIN <const> = 1772321400

local function test_summarize_groups_by_month_in_a_zone()
  local txs = { tx(LATE_JANUARY, 1250, "food"), tx(FEBRUARY, -350, "food"),
    tx(MARCH_IN_BERLIN, 25, "misc") }
  local report, why = ledger.summarize(txs, { zone = "America/New_York" })
  assert(report ~= nil, why)
  local r: ledger.Report = report
  assert(r.rows == 3, "rows " .. r.rows)
  assert(#r.months == 2, #r.months .. " months")
  local jan: ledger.Month = r.months[1]
  assert(jan.month == "2026-01" and jan.total_cents == 1250 and jan.categories["food"] == 1250,
    "January in New York")
  local feb = r.months[2]
  assert(feb.month == "2026-02" and feb.total_cents == -325 and feb.categories["misc"] == 25 and
      feb.categories["food"] == -350, "February in New York")
  local utc = assert(ledger.summarize(txs, {}))
  assert(#utc.months == 1 and utc.months[1].month == "2026-02" and utc.months[1].total_cents == 925,
    "UTC")
end

local function test_summarize_keeps_only_dates_within_the_bounds()
  local txs = { tx(LATE_JANUARY, 1250, "food"), tx(FEBRUARY, -350, "food"),
    tx(MARCH_IN_BERLIN, 25, "misc") }
  local report = assert(ledger.summarize(txs, { zone = "Europe/Berlin", from = "2026-02-01",
    to = "2026-02-28" }))
  assert(report.rows == 2 and #report.months == 1 and report.months[1].total_cents == 900,
    "Berlin, February")
  report = assert(ledger.summarize(txs, { from = "2026-03-01" }))
  assert(report.rows == 0 and #report.months == 0, "nothing in March in UTC")
end

local function test_summarize_refuses_an_unknown_zone_or_date()
  local txs = { tx(FEBRUARY, 100, "food") }
  local report, why = ledger.summarize(txs, { zone = "Mars/Olympus" })
  assert(report == nil and why ~= "", "an unknown zone was taken")
  report, why = ledger.summarize(txs, { from = "yesterday" })
  assert(report == nil and why ~= "", "a malformed date was taken")
end
