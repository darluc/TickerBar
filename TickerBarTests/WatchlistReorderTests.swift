import XCTest
import GRDB
@testable import TickerBar

@MainActor
final class WatchlistReorderTests: XCTestCase {
    private var tempDir: URL!
    private var database: TickerBar.Database!
    private var watchlistRepo: WatchlistRepository!
    private var settingsRepo: SettingsRepository!
    private var refresher: QuoteRefresher!
    private var viewModel: PopoverViewModel!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbPath = tempDir.appendingPathComponent("test.sqlite").path
        database = try TickerBar.Database(path: dbPath)
        watchlistRepo = WatchlistRepository(dbPool: database.dbPool)
        settingsRepo = SettingsRepository(dbPool: database.dbPool)

        let clock = MarketClock()
        let tencent = TencentProvider()
        let orchestrator = ProviderOrchestrator(
            providers: [.tencent: tencent],
            preferences: ProviderPreference.defaults
        )
        let quoteCache = QuoteCacheRepository(dbPool: database.dbPool)
        refresher = QuoteRefresher(
            provider: orchestrator,
            watchlistRepo: watchlistRepo,
            clock: clock,
            quoteCacheRepo: quoteCache,
            settingsRepo: settingsRepo
        )
        viewModel = PopoverViewModel(
            refresher: refresher,
            watchlistRepo: watchlistRepo,
            settingsRepo: settingsRepo
        )
    }

    override func tearDown() async throws {
        viewModel = nil
        refresher = nil
        watchlistRepo = nil
        settingsRepo = nil
        database = nil
        try? FileManager.default.removeItem(at: tempDir)
        try await super.tearDown()
    }

    func testXueqiuNightSessionFetch() async throws {
        let sym = SymbolID(code: "GOOGL", market: .us)
        let xq = XueqiuProvider()
        let result = try await xq.fetch([sym])
        guard let q = result[sym] else {
            XCTFail("Xueqiu should return quote for GOOGL")
            return
        }
        XCTAssertGreaterThan(q.price, 0)
        print("XUEQIU_GOOGL: price=\(q.price), isExtended=\(q.isExtended), extPrice=\(String(describing: q.extendedPrice)), session=\(String(describing: q.extendedSession)), effPrice=\(q.effectivePrice)")
        // Verify that during overnight session, extendedPrice is populated with the night session price (~274)
        if MarketClock().usExtendedSession() == .overnight {
            XCTAssertTrue(q.isExtended)
            XCTAssertNotNil(q.extendedPrice)
            if let ext = q.extendedPrice {
                XCTAssertGreaterThan(ext, 200)
                XCTAssertLessThan(ext, 300)
            }
        }
    }

    func testSinaExtendedFetch() async throws {
        let sym = SymbolID(code: "AAPL", market: .us)
        let sina = SinaProvider()
        let result = try await sina.fetch([sym])
        guard let q = result[sym] else {
            XCTFail("Sina should return quote for AAPL")
            return
        }
        XCTAssertGreaterThan(q.price, 0)
        print("SINA_AAPL: price=\(q.price), isExtended=\(q.isExtended), extPrice=\(String(describing: q.extendedPrice)), session=\(String(describing: q.extendedSession))")
    }

    func testTencentExtendedParse() throws {
        let sym = SymbolID(code: "AAPL", market: .us)
        let raw = #"v_usAAPL="200~苹果~AAPL.OQ~331.90~338.32~325.58~63160026~0~0~329.80~14280~0~0~0~0~0~0~0~0~329.96~80~0~0~0~0~0~0~0~0~~2026-11-03 16:00:02~-6.42~-1.90~334.50~325.33~USD~63160026~20893976633~0.43~38.06~~44.49~~2.71~48407.97637~48438.08342~Apple Inc.~8.72~351.73~242.76~14200~45.05~0.32~48438.08342~22.42~-4.38~GP~148.75~36.08~-2.24~-0.52~7.67~14594180000~14585108878~1.26~36.18~1.06~330.81~~~~~";"#
        let tencent = TencentProvider()
        let result = tencent.parse(raw, encodedPairs: [("usAAPL", sym)])
        guard let q = result[sym] else {
            XCTFail("Tencent should parse AAPL")
            return
        }
        XCTAssertEqual(q.price, Decimal(string: "331.90"))
        // If current session is an extended session, extendedPrice should be populated from field 67
        if MarketClock().usExtendedSession() != nil {
            XCTAssertTrue(q.isExtended)
            XCTAssertEqual(q.extendedPrice, Decimal(string: "330.81"))
            XCTAssertEqual(q.effectivePrice, Decimal(string: "330.81"))
        }
    }

    func testReorderWatchItemMovesItemToTargetPosition() throws {
        let itemA = WatchItem(symbol: SymbolID(code: "AAPL", market: .us), name: "Apple", order: 0)
        let itemB = WatchItem(symbol: SymbolID(code: "TSLA", market: .us), name: "Tesla", order: 1)
        let itemC = WatchItem(symbol: SymbolID(code: "NVDA", market: .us), name: "Nvidia", order: 2)
        try watchlistRepo.upsert(itemA)
        try watchlistRepo.upsert(itemB)
        try watchlistRepo.upsert(itemC)
        viewModel.reload()

        XCTAssertEqual(viewModel.watchlist.map(\.symbol.code), ["AAPL", "TSLA", "NVDA"])

        // Move Apple (index 0) to Nvidia's position (index 2)
        viewModel.reorderWatchItem(from: itemA.id, to: itemC.id)
        XCTAssertEqual(viewModel.watchlist.map(\.symbol.code), ["TSLA", "NVDA", "AAPL"])

        // Persisted state matches
        let persisted = try watchlistRepo.all()
        XCTAssertEqual(persisted.map(\.symbol.code), ["TSLA", "NVDA", "AAPL"])

        // Move Tesla (index 0) to Nvidia (index 1)
        viewModel.reorderWatchItem(from: itemB.id, to: itemC.id)
        XCTAssertEqual(viewModel.watchlist.map(\.symbol.code), ["NVDA", "TSLA", "AAPL"])

        // Moving to same index is no-op
        viewModel.reorderWatchItem(from: itemC.id, to: itemC.id)
        XCTAssertEqual(viewModel.watchlist.map(\.symbol.code), ["NVDA", "TSLA", "AAPL"])
    }

    func testMultipleWatchlistsCreateRenameDelete() throws {
        // Initially has default group
        XCTAssertEqual(viewModel.groups.count, 1)
        let defaultGroup = viewModel.groups[0]
        XCTAssertEqual(defaultGroup.name, "Watchlist")

        // Add an item to default group
        let apple = WatchItem(symbol: SymbolID(code: "AAPL", market: .us), name: "Apple", watchlistId: defaultGroup.id)
        try watchlistRepo.upsert(apple)
        viewModel.reload()
        XCTAssertEqual(viewModel.watchlist.map(\.symbol.code), ["AAPL"])

        // Create a new group
        let newGroup = viewModel.createGroup(name: "US Tech")
        XCTAssertEqual(viewModel.groups.count, 2)
        XCTAssertEqual(viewModel.selectedGroupID, newGroup.id)
        XCTAssertEqual(viewModel.watchlist.count, 0) // New group is empty

        // Add Tesla to new group
        let tesla = WatchItem(symbol: SymbolID(code: "TSLA", market: .us), name: "Tesla", watchlistId: newGroup.id)
        try watchlistRepo.upsert(tesla)
        viewModel.reload()
        XCTAssertEqual(viewModel.watchlist.map(\.symbol.code), ["TSLA"])

        // Switch back to default group
        viewModel.selectGroup(id: defaultGroup.id)
        XCTAssertEqual(viewModel.watchlist.map(\.symbol.code), ["AAPL"])

        // Rename new group
        viewModel.renameGroup(id: newGroup.id, newName: "Magnificent")
        let updatedGroups = try watchlistRepo.allGroups()
        XCTAssertEqual(updatedGroups.first(where: { $0.id == newGroup.id })?.name, "Magnificent")

        // Delete the new group
        viewModel.deleteGroup(id: newGroup.id)
        XCTAssertEqual(viewModel.groups.count, 1)
        XCTAssertEqual(viewModel.selectedGroupID, defaultGroup.id)
        XCTAssertEqual(viewModel.watchlist.map(\.symbol.code), ["AAPL"])

        // Tesla was cascade deleted
        let remaining = try watchlistRepo.all()
        XCTAssertEqual(remaining.map(\.symbol.code), ["AAPL"])
    }
}
