import XCTest
@testable import TickerBar

final class ETFMonitorTests: XCTestCase {
    func testPreparedDisplayPreservesAmountsCoverageAndHistory() {
        let now = ISO8601DateFormatter().date(from: "2026-11-06T03:00:00Z")!
        let yesterday = ETFHistory.Day(date: "2026-11-05", basketTurnover: 10e8,
                                       basketNetFlow: 2e8, broadMarketFlows: ["沪深300": 3e8])
        let history = ETFHistory(version: 1, source: "test", basketCodes: ETFDescriptor.basket.map(\.code),
                                 days: [yesterday], curves: [])
        var capture = ETFStore.Capture()
        capture.quotes = [
            .init(code: "510310", amount: 3e8, changePercent: 1, timestamp: now),
            .init(code: "000001", amount: 1000e8, changePercent: 1, timestamp: now)
        ]
        capture.minutes = ["510310": [.init(stamp: "2026-11-06 09:30", close: 1, amount: 1e8)]]
        for etf in ETFDescriptor.basket { capture.daily[etf.code] = ["2026-11-05": 1e8] }
        let display = ETFPresentation.build(capture: capture, history: history, now: now)
        XCTAssertEqual(display.day, "2026-11-06")
        XCTAssertEqual(display.total, 3e8)
        XCTAssertEqual(display.aggregates.first?.cumulative, 1e8)
        XCTAssertEqual(display.minimumCoverage, 1)
        XCTAssertEqual(display.minuteMissing.count, 19)
        XCTAssertEqual(display.flowByDate["2026-11-05"]?.basketTurnover, 20e8)
        XCTAssertEqual(display.flowByDate["2026-11-05"]?.basketNetFlow, 2e8)
        XCTAssertEqual(display.broadCumulative.last?.amount, 3e8)
        // UI selection and rendering only read this prepared value; no archive rebuild.
        capture.quotes = []
        XCTAssertEqual(display.quotes.count, 1)
    }

    func testFixedBasketAndExchangeEncoding() {
        XCTAssertEqual(ETFDescriptor.basket.count, 20)
        XCTAssertEqual(Set(ETFDescriptor.basket.map(\.code)).count, 20)
        XCTAssertFalse(ETFDescriptor.basket.contains { $0.code == "000001" })
        XCTAssertEqual(ETFDescriptor.basket.first { $0.code == "159919" }?.secid, "0.159919")
        XCTAssertEqual(ETFDescriptor.basket.first?.secid, "1.510310")
    }
    func testMinuteAmountsAreNotVolumeAndDuplicatesDoNotDoubleCount() {
        let rows = ETFService.parseMinutes([
            "2026-11-05 09:30,4,4,4,4,100,40000,4",
            "2026-11-06 09:30,4,4,4,4,100,41000,4",
            "2026-11-06 09:30,4,4,4,4,110,44000,4",
            "2026-11-06 12:00,4,4,4,4,100,99999,4",
            "2026-11-06 09:31,4,4,4,4,100,-1,4"
        ])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.last?.amount, 44000)
        let series = ["510310": rows, "000001": rows]
        let aggregate = ETFMath.aggregate(series, day: "2026-11-06")
        XCTAssertEqual(aggregate.count, 1)
        XCTAssertEqual(aggregate.first?.amount, 44000)
        XCTAssertEqual(aggregate.first?.coverage, 1)
    }
    func testShanghaiTimeAndSessionCoordinate() {
        XCTAssertEqual(ETFTime.slot("2026-11-06 09:30"), 0)
        XCTAssertEqual(ETFTime.slot("2026-11-06 11:30"), 120)
        XCTAssertEqual(ETFTime.slot("2026-11-06 13:00"), 121)
        XCTAssertEqual(ETFTime.slot("2026-11-06 15:00"), 241)
        XCTAssertNil(ETFTime.slot("2026-11-06 12:15"))
        XCTAssertNil(ETFTime.slot("2026-02-30 09:30"))
        let utc = ISO8601DateFormatter().date(from: "2026-11-05T16:01:00Z")!
        XCTAssertEqual(ETFTime.day(utc), "2026-11-06")
    }
    func testIncompleteCoverageIsPreservedAndCumulativeResetsByDay() {
        let a = ETFMinute(stamp: "2026-11-06 09:30", close: 1, amount: 1e8)
        let b = ETFMinute(stamp: "2026-11-06 09:31", close: 1, amount: 2e8)
        var input = Dictionary(uniqueKeysWithValues: ETFDescriptor.basket.map { ($0.code, [a, b]) })
        input["510310"] = [a]
        input["000001"] = [a, b]
        let result = ETFMath.aggregate(input, day: "2026-11-06")
        XCTAssertEqual(result.map(\.coverage), [20, 19])
        XCTAssertEqual(result.last?.cumulative, 58e8)
        XCTAssertTrue(ETFMath.aggregate(input, day: "2026-11-05").isEmpty)
    }
    func testSnapshotUnitsAndMissingValues() {
        let rows = ETFService.parseSnapshots(["diff": [
            ["f12": "510310", "f6": 1e8, "f3": -1.38, "f124": 1793952718],
            ["f12": "159919", "f6": "-", "f3": "-", "f124": 1793952718],
            ["f12": "510300", "f6": 0, "f3": "-", "f124": 1793952718]
        ]])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.first?.amount, 1e8)
        XCTAssertEqual(rows.first?.changePercent, -1.38)
        XCTAssertNil(rows.last?.changePercent)
    }
    func testArchiveMergeAndRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ETFStore(directory: dir)
        let old = ETFMinute(stamp: "2026-11-05 09:30", close: 1, amount: 100)
        let corrected = ETFMinute(stamp: old.stamp, close: 1, amount: 200)
        let today = ETFMinute(stamp: "2026-11-06 09:30", close: 1, amount: 300)
        let merged = ETFStore.merge([old], [corrected, today])
        XCTAssertEqual(merged.map(\.amount), [200, 300])
        var capture = ETFStore.Capture()
        capture.minutes = ["510310": merged]
        try store.save(capture, name: "capture.json")
        XCTAssertEqual(store.loadCapture().minutes["510310"]?.map(\.amount), [200, 300])
    }
    func testSeedSemanticsAndHistoryValidation() throws {
        let bundle = Bundle(for: ETFMonitor.self)
        let url = try XCTUnwrap(bundle.url(forResource: "etf-history-seed", withExtension: "json"))
        let data = try Data(contentsOf: url)
        let history = try ETFHistory.decode(data)
        XCTAssertEqual(history.days.count, 747)
        let latest = try XCTUnwrap(history.days.first { $0.date == "2026-11-05" })
        XCTAssertEqual(try XCTUnwrap(latest.basketNetFlow) / 1e8, 65.06, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(latest.broadMarketFlows?.values.reduce(0, +)) / 1e8, 103.94, accuracy: 0.1)
        XCTAssertFalse(latest.isSignal)
        XCTAssertTrue(history.days.first { $0.date == "2026-11-04" }!.isSignal)
        XCTAssertEqual(history.samples?.dailyCount, 65)
        XCTAssertEqual(history.samples?.signalCount, 33)
        let average = try XCTUnwrap(history.curves.first { $0.date == nil })
        XCTAssertEqual(average.endDate, "2026-11-04")
        XCTAssertTrue(average.interpolated)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["basketCodes"] = ["510310"]
        XCTAssertThrowsError(try ETFHistory.decode(JSONSerialization.data(withJSONObject: object)))
    }
    func testSignalThresholdIsStrictlyGreaterThan100Yi() {
        let d = ETFHistory.Day(date: "2026-11-06", basketTurnover: 1000e8, basketNetFlow: 100e8, broadMarketFlows: nil)
        XCTAssertFalse(d.isSignal)
    }
}
