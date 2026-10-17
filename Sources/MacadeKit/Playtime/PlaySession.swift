import Foundation

/// One time a game was played: when it started and for how long.
public struct PlaySession: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var gameID: String
    public var start: Date
    public var duration: TimeInterval

    public init(id: UUID = UUID(), gameID: String, start: Date, duration: TimeInterval) {
        self.id = id
        self.gameID = gameID
        self.start = start
        self.duration = duration
    }

    /// "steam:268910" -> .steam
    public var store: StoreKind? { PlaySession.store(of: gameID) }

    public static func store(of gameID: String) -> StoreKind? {
        gameID.split(separator: ":", maxSplits: 1).first.flatMap { StoreKind(rawValue: String($0)) }
    }
}

public struct SessionFile: Codable, Equatable, Sendable {
    public var sessions: [PlaySession] = []
    public init() {}
}

/// `Sessions.json`. Sessions shorter than `minimumDuration` are noise (a game that failed to start).
public struct SessionStore: Sendable {
    public static let minimumDuration: TimeInterval = 10
    /// Old sessions beyond this many are dropped, oldest first, so the file never grows without end.
    public static let maximumCount = 20_000

    let store: JSONStore<SessionFile>

    public init(paths: Paths) { store = JSONStore(url: paths.sessionsFile) }

    public func load() -> [PlaySession] { store.load(default: SessionFile()).sessions }

    public func save(_ sessions: [PlaySession]) {
        var file = SessionFile()
        file.sessions = Array(sessions.suffix(Self.maximumCount))
        try? store.save(file)
    }
}

/// Totals for the stats page. Pure functions over sessions, so they are easy to test.
public enum PlaytimeStats {
    public enum Period: String, CaseIterable, Sendable, Identifiable {
        case week, month, allTime
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .week: "This week"
            case .month: "This month"
            case .allTime: "All time"
            }
        }
    }

    public struct GameTotal: Equatable, Sendable, Identifiable {
        public var gameID: String
        public var seconds: TimeInterval
        public var id: String { gameID }
        public var store: StoreKind? { PlaySession.store(of: gameID) }
    }

    public struct StoreTotal: Equatable, Sendable, Identifiable {
        public var store: StoreKind
        public var seconds: TimeInterval
        public var id: StoreKind { store }
    }

    public struct WeekTotal: Equatable, Sendable, Identifiable {
        public var weekStart: Date
        public var seconds: TimeInterval
        public var id: Date { weekStart }
    }

    /// Per-game seconds in `period`. "All time" also counts what was played before sessions were
    /// recorded (`allTime`, the per-game total kept in the library), whichever is larger.
    public static func perGame(sessions: [PlaySession], allTime: [String: TimeInterval], period: Period,
                               now: Date = Date(), calendar: Calendar = .current) -> [GameTotal] {
        var totals: [String: TimeInterval] = [:]
        if let start = periodStart(period, now: now, calendar: calendar) {
            for s in sessions where s.start >= start && s.start <= now { totals[s.gameID, default: 0] += s.duration }
        } else {
            for s in sessions { totals[s.gameID, default: 0] += s.duration }
            for (id, seconds) in allTime { totals[id] = max(totals[id] ?? 0, seconds) }
        }
        return totals.filter { $0.value > 0 }
            .map { GameTotal(gameID: $0.key, seconds: $0.value) }
            .sorted { $0.seconds != $1.seconds ? $0.seconds > $1.seconds : $0.gameID < $1.gameID }
    }

    public static func perStore(_ games: [GameTotal]) -> [StoreTotal] {
        var totals: [StoreKind: TimeInterval] = [:]
        for g in games { if let store = g.store { totals[store, default: 0] += g.seconds } }
        return totals.map { StoreTotal(store: $0.key, seconds: $0.value) }
            .sorted { $0.seconds != $1.seconds ? $0.seconds > $1.seconds : $0.store.rawValue < $1.store.rawValue }
    }

    /// The last `weeks` calendar weeks, oldest first, empty weeks included. A session belongs to the week it started in.
    public static func weekly(sessions: [PlaySession], weeks: Int, now: Date = Date(),
                              calendar: Calendar = .current) -> [WeekTotal] {
        guard weeks > 0, let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start else { return [] }
        let starts = (0..<weeks).reversed().compactMap { calendar.date(byAdding: .weekOfYear, value: -$0, to: thisWeek) }
        var totals = Dictionary(uniqueKeysWithValues: starts.map { ($0, 0.0) })
        for s in sessions {
            guard let week = calendar.dateInterval(of: .weekOfYear, for: s.start)?.start, totals[week] != nil else { continue }
            totals[week]! += s.duration
        }
        return starts.map { WeekTotal(weekStart: $0, seconds: totals[$0] ?? 0) }
    }

    /// Start of the period; nil for all time. "Week" and "month" are the current calendar week and month.
    static func periodStart(_ period: Period, now: Date, calendar: Calendar) -> Date? {
        switch period {
        case .week: calendar.dateInterval(of: .weekOfYear, for: now)?.start
        case .month: calendar.dateInterval(of: .month, for: now)?.start
        case .allTime: nil
        }
    }
}
