import Foundation

// Self-check for the pure logic in Sources/Logic.swift. Run with `./build.sh test`.

var failures = 0
func check(_ ok: Bool, _ what: String, line: Int = #line) {
    if !ok { failures += 1; print("FAIL line \(line): \(what)") }
}

// ps parsing, including a path with spaces and multi-day elapsed time
let row = PS.parse("  584     1     0  49.0 2761520 64-15:23:39 1234:56.78 /Applications/Spotify.app/Contents/Frameworks/Spotify Helper (Renderer).app/Contents/MacOS/Spotify Helper (Renderer)")
check(row?.pid == 584 && row?.ppid == 1 && row?.uid == 0, "ps ids")
check(row?.name == "Spotify Helper (Renderer)", "ps path with spaces")
let expectedElapsed: TimeInterval = 64 * 86400 + 15 * 3600 + 23 * 60 + 39
let expectedCPU: TimeInterval = 1234 * 60 + 56.78
check(row?.elapsed == expectedElapsed, "elapsed with days")
check(abs((row?.cpuTime ?? 0) - expectedCPU) < 0.001, "cpu time past 59 minutes")
check(PS.parse("garbage") == nil, "reject garbage")

// CPU window: 1.3 cores busy for 10 minutes
var w = CPUWindow()
var avg: Double?
for i in 0...300 { avg = w.add(t: Double(i * 2), cpu: Double(i * 2) * 1.3, window: 600) }
check(avg.map { abs($0 - 130) < 0.5 } ?? false, "window average 130 %, got \(String(describing: avg))")
var w2 = CPUWindow()
check(w2.add(t: 0, cpu: 0, window: 600) == nil, "no average before the window is covered")

// Alert gate: sustain, fire once, re-arm only after clearing and cooldown
var g = AlertGate(sustain: 120)
check(!g.update(true, now: 0), "not yet")
check(g.update(true, now: 120), "fires after sustain")
check(!g.update(true, now: 200), "fires only once while active")
check(!g.update(false, now: 300), "clears")
check(!g.update(true, now: 400), "sustain starts again")
check(!g.update(true, now: 600), "cooldown blocks")
check(g.update(true, now: 1100), "fires after cooldown")

// Frequencies map by position, not by the number in the state name
let states: [(name: String, residency: Int64)] = [("IDLE", 50), ("V0P2", 0), ("V1P1", 0), ("V2P0", 50)]
let f = Freq.accumulate(states, table: [600, 1000, 3000])
check(f.active == 50 && f.weighted / Double(f.active) == 3000, "highest state is last")

// Process descriptions
check(Describe.tool(path: "/usr/local/bin/node", args: ["node", "/x/node_modules/vitest/vitest.mjs", "--run"]) == "vitest", "vitest")
check(Describe.tool(path: "/usr/local/bin/node", args: ["node", "/x/node_modules/.bin/vue-tsc", "--noEmit"]) == "vue-tsc", "vue-tsc not tsc")
check(Describe.tool(path: "/Users/a/Library/Caches/ms-playwright/chromium-1169/chrome-mac/Chromium.app/Contents/MacOS/Chromium", args: []) == "playwright", "playwright chromium")
check(Describe.tool(path: "/usr/local/bin/node", args: ["node", "--disable-warning=X", "/a/app/src/cli.ts", "serve"]) == "cli.ts", "script name")
check(Describe.title(path: "/a/Chromium", args: ["Chromium", "--headless=new"]) == "Chromium (headless)", "headless")
check(Describe.tool(path: "/Applications/Spotify.app/Contents/MacOS/Spotify", args: []) == nil, "no tool for apps")

// lsof
let l = Lsof.parse("p123\nf4\nn*:5173\np456\nn127.0.0.1:8770\nn[::1]:5432\n")
check(l.count == 3 && l[0].pid == 123 && l[0].port == 5173 && l[2].host == "[::1]" && l[2].pid == 456, "lsof parse")

// SMART log: values from the real disk on 18.11.2026
var log = [UInt8](repeating: 0, count: 512)
log[1] = 0x3E; log[2] = 0x01        // 318 K
log[3] = 100; log[4] = 99; log[5] = 10
func put(_ v: UInt64, at o: Int) { for i in 0..<8 { log[o + i] = UInt8((v >> (8 * UInt64(i))) & 0xff) } }
put(452_411_380, at: 48)            // data units written ≈ 231.6 TB
put(7157, at: 128)
put(11, at: 144)
let smart = SMART(log: log)
check(smart?.tempC == 45 && smart?.percentUsed == 10 && smart?.powerOnHours == 7157 && smart?.unsafeShutdowns == 11, "smart fields")
check(abs((smart?.writtenBytes ?? 0) / 1e12 - 231.6) < 0.1, "smart written TB")
check(smart?.level == 0, "healthy disk")
log[160] = 1
check(SMART(log: log)?.level == 2, "media error is a problem")
check(SMART(log: [1, 2, 3]) == nil, "short log")

check(Fmt.age(15 * 86400 + 5) == "15 T" && Fmt.age(3 * 3600) == "3 h" && Fmt.age(30) == "1 min", "age format")

print(failures == 0 ? "selfcheck ok" : "selfcheck: \(failures) failure(s)")
exit(failures == 0 ? 0 : 1)
