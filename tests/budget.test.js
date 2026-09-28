// Run: TZ=Europe/Madrid node tests/budget.test.js
const assert = require("assert")
// Budget.js starts with QML's ".pragma library", which is not JavaScript.
const src = require("fs").readFileSync(require("path").join(__dirname, "../Budget.js"), "utf8").replace(/^\.pragma library\n/, "")
const mod = { exports: {} }
new Function("module", src)(mod)
const B = mod.exports

const H = 3600000, D = 24 * H
const at = (y, m, d, h, min) => new Date(y, m - 1, d, h || 0, min || 0).getTime()
const week = (resetMs) => ({ reset: resetMs, span: 7 * D })
const work = B.defaultConfig()
const every = B.config("Every day", "", 9, 19)

// A week that ends Wed 30 Sep 15:00 and started Wed 23 Sep 15:00.
const reset = at(2026, 9, 30, 15)
const p = (cfg, used, now) => B.pace(cfg, used, reset, 7 * D, now)

// Working days: Wed 4h + Thu..Tue 5x10h... (Wed 23 15-19, Thu, Fri, Mon, Tue full, Wed 9-15).
assert.strictEqual(B.workMs(work, reset - 7 * D, reset) / H, 50)
assert.ok(Math.abs(p(work, 0.12, at(2026, 9, 24, 13, 37)).budget - 0.1723) < 0.001)
// Flat all weekend and overnight.
assert.strictEqual(p(work, 0.3, at(2026, 9, 26, 20)).budget, p(work, 0.3, at(2026, 9, 27, 12)).budget)
// Every day is linear.
assert.ok(Math.abs(p(every, 0.5, reset - 3.5 * D).budget - 0.5) < 1e-9)

// Audit: zero working days behaves as every day, and says so in the config.
const none = B.config("Working days", "", 9, 19)
assert.strictEqual(none.everyDay, true)
assert.ok(Math.abs(p(none, 0.5, reset - 3.5 * D).budget - 0.5) < 1e-9)
// Audit: a backwards or empty hour range also falls back.
assert.strictEqual(B.config("Working days", "Mon", 19, 9).everyDay, true)
assert.strictEqual(B.config("Working days", "Mon", 9, 9).everyDay, true)

// Audit: a figure outside its window is not a pace (stale reset, or not started).
assert.strictEqual(p(work, 0.1, reset + 1), null)
assert.strictEqual(p(work, 0.1, reset - 8 * D), null)

// Pace words.
assert.strictEqual(p(work, 0.12, at(2026, 9, 24, 13, 37)).state, "under")
assert.strictEqual(p(work, 0.5, at(2026, 9, 24, 13, 37)).state, "over")
assert.strictEqual(p(work, 0.17, at(2026, 9, 24, 13, 37)).state, "on")
assert.strictEqual(p(work, 0.05, reset - 7 * D + H / 2).state, "early")
assert.strictEqual(B.paceLine(0.12, p(work, 0.12, at(2026, 9, 24, 13, 37))), "12% used · budget 17% · 5% under pace")

// Projection: fits at exactly 100% is "fits" (audit), no "0m before the reset".
const now = at(2026, 9, 24, 13, 37)
const q = p(work, 0.12, now)
assert.ok(Math.abs(q.projected - 0.12 / q.budget) < 1e-9)
assert.match(B.forecastLine(0.12, q, reset, now), /^At this rate: about 70% at reset$/)
const exact = B.pace(every, 0.5, reset, 7 * D, reset - 3.5 * D)
assert.strictEqual(exact.projected, 1)
assert.match(B.forecastLine(0.5, exact, reset, reset - 3.5 * D), /about 100% at reset/)
// Burning too fast: says when it empties, always before the reset.
const fast = p(work, 0.6, now)
assert.ok(fast.projected > 1 && fast.emptyAtMs > now && fast.emptyAtMs < reset)
assert.match(B.forecastLine(0.6, fast, reset, now), /^At this rate: full .* before the reset$/)
// Audit: a full window says so, it does not print "empty today 13:37".
assert.match(B.forecastLine(1, p(work, 1, now), reset, now), /^Empty now · back at Wed 30 Sep 15:00$/)
// No use, nothing to project.
assert.strictEqual(B.forecastLine(0, p(work, 0, now), reset, now), "")

// Audit: labels say tomorrow, and carry the date a week out.
assert.strictEqual(B.whenText(at(2026, 9, 25, 9), now), "tomorrow 09:00")
assert.strictEqual(B.whenText(at(2026, 9, 24, 18), now), "today 18:00")
assert.strictEqual(B.whenText(at(2026, 9, 30, 15), at(2026, 9, 23, 16)), "Wed 30 Sep 15:00")

// Audit: DST. The week Wed 21 Oct 15:00 to Wed 28 Oct 15:00 is 169 real hours in
// Madrid; the pace must follow real time, so the midpoint is not 84 h in.
if (process.env.TZ === "Europe/Madrid") {
  const r = at(2026, 10, 28, 15), span = 7 * D + H
  const real = B.pace(every, 0.5, r, span, at(2026, 10, 21, 15) + span / 2)
  assert.ok(Math.abs(real.budget - 0.5) < 1e-9)
  assert.strictEqual(B.workMs(work, at(2026, 10, 25), at(2026, 10, 26)), 0) // Sunday
  assert.strictEqual(B.workMs(B.config("Working days", "Sun", 0, 24), at(2026, 10, 25), at(2026, 10, 26)), 25 * H)
}
// Review: heavy use in the first hours reads as over, and never divides by zero.
const eager = B.pace(work, 0.6, at(2026, 9, 25, 20), 7 * D, at(2026, 9, 21, 9, 20))
assert.strictEqual(eager.state, "over")
const atStart = B.pace(work, 0.6, reset, 7 * D, reset - 7 * D)
assert.ok(atStart === null || atStart.projected < 0 || isFinite(atStart.projected))
// Percentages: Remaining shows what is left (1 - used); Used stays as it was.
// Rounded once on the used side, so the two modes always add up to 100.
const early = B.pace(work, 0.21, reset, 7 * D, reset - 7 * D + 60000)
assert.strictEqual(B.paceLine(0.21, early), "21% used · budget 0% · 21% over pace")
assert.strictEqual(B.paceLine(0.21, early, "Used"), "21% used · budget 0% · 21% over pace")
assert.strictEqual(B.paceLine(0.21, early, "Remaining"), "79% left · budget 100% · 21% over pace")
assert.strictEqual(B.paceLine(0.12, q, "Remaining"), "88% left · budget 83% · 5% under pace")
assert.strictEqual(B.paceLine(0.3, null, "Remaining"), "70% left")
assert.strictEqual(B.paceLine(0.3, null, "Used"), "30% used")
assert.strictEqual(B.paceLine(1.2, null, "Remaining"), "0% left")
const at64 = { budget: 0.5, diff: 0, state: "on", projected: 0.64, emptyAtMs: -1, full: false }
assert.strictEqual(B.forecastLine(0.32, at64, reset, now, "Used"), "At this rate: about 64% at reset")
assert.strictEqual(B.forecastLine(0.32, at64, reset, now, "Remaining"), "At this rate: about 36% left at reset")
const noEmpty = { budget: 0.5, diff: 0.3, state: "over", projected: 1.6, emptyAtMs: -1, full: false }
assert.strictEqual(B.forecastLine(0.8, noEmpty, reset, now, "Used"), "At this rate: full before the reset")
assert.strictEqual(B.forecastLine(0.8, noEmpty, reset, now, "Remaining"), "At this rate: runs out before the reset")
assert.strictEqual(B.forecastLine(0.6, fast, reset, now), B.forecastLine(0.6, fast, reset, now, "Used"))
assert.match(B.forecastLine(0.6, fast, reset, now, "Remaining"), /^At this rate: runs out (today|tomorrow|\w{3} \d+ \w{3}) \d\d:\d\d · .+ before the reset$/)
assert.strictEqual(B.forecastLine(0.6, fast, reset, now, "Remaining").replace("runs out", "full"), B.forecastLine(0.6, fast, reset, now, "Used"))
assert.strictEqual(B.forecastLine(1, p(work, 1, now), reset, now, "Remaining"), "Empty now · back at Wed 30 Sep 15:00")
assert.strictEqual(B.forecastLine(0, p(work, 0, now), reset, now, "Remaining"), "")
// The figure a meter or a label shows.
assert.strictEqual(B.remaining("Remaining"), true)
assert.strictEqual(B.remaining("Used"), false)
assert.strictEqual(B.remaining(undefined), false)
assert.strictEqual(B.shown(0.21, "Used"), 0.21)
assert.ok(Math.abs(B.shown(0.21, "Remaining") - 0.79) < 1e-9)
assert.strictEqual(B.shown(0, "Remaining"), 1)
assert.strictEqual(B.shown(1.3, "Remaining"), 0)
assert.strictEqual(B.shown(-1, "Remaining"), -1)
assert.strictEqual(B.percentText(0.21, "Used"), "21%")
assert.strictEqual(B.percentText(0.21, "Remaining"), "79%")
assert.strictEqual(B.percentText(0.125, "Used"), "13%")
assert.strictEqual(B.percentText(0.125, "Remaining"), "87%")
// The window an account card and a provider row stand for: the five-hour
// session, then the week, then the fullest of whatever else there is.
const win = (kind, percent) => ({ kind: kind, percent: percent })
const sess = win("session", 0.25), wk = win("weekly", 0.49)
assert.strictEqual(B.headline([wk, sess]), sess)
assert.strictEqual(B.headline([sess, wk]), sess)
// The first session is the account-wide one; model-scoped ones follow it.
const modelSess = win("session", 0.9)
assert.strictEqual(B.headline([sess, modelSess, wk]), sess)
// No session figure: the week stands in for it.
assert.strictEqual(B.headline([wk, win("other", 0.95)]), wk)
// Neither (a monthly quota, a model's own cap): the fullest, as before.
const month = win("month", 0.3), cap = win("other", 0.7)
assert.strictEqual(B.headline([month, cap]), cap)
assert.strictEqual(B.headline([]), null)
assert.strictEqual(B.headline(undefined), null)
// A card reads "N% left" in Remaining and "N% used" in Used.
assert.strictEqual(B.headlineText(0.25, "Remaining"), "75% left")
assert.strictEqual(B.headlineText(0.25, "Used"), "25% used")
console.log("budget: all passed")
