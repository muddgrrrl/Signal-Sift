import AppKit
import Foundation
import SwiftUI

private typealias ViewState<Value> = SwiftUI.State<Value>

enum NewsSource: String, CaseIterable, Identifiable, Sendable {
    case hackerNews = "Hacker News"
    case worldNews = "GDELT"

    var id: Self { self }

    func request(query: String, days: Int, now: Date = Date()) -> URLRequest {
        var url: URLComponents
        switch self {
        case .hackerNews:
            url = URLComponents(string: "https://hn.algolia.com/api/v1/search")!
            url.queryItems = [
                .init(name: "query", value: query), .init(name: "tags", value: "story"),
                .init(name: "hitsPerPage", value: "40"),
                .init(name: "numericFilters", value: "created_at_i>\(Int(now.timeIntervalSince1970) - days * 86400)")
            ]
        case .worldNews:
            url = URLComponents(string: "https://api.gdeltproject.org/api/v2/doc/doc")!
            url.queryItems = [
                .init(name: "query", value: query), .init(name: "mode", value: "artlist"),
                .init(name: "format", value: "json"), .init(name: "maxrecords", value: "40"),
                .init(name: "timespan", value: "\(days)d")
            ]
        }
        // Some providers decode query parameters as form data.
        url.percentEncodedQuery = url.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        var request = URLRequest(url: url.url!, timeoutInterval: 12)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }
}

struct Story: Identifiable, Sendable {
    let title: String
    let url: URL
    let date: Date?
    let discussion: URL?
    let source: NewsSource

    var id: String { Self.canonical(url) }

    static func link(_ text: String?) -> URL? {
        guard let text, let parts = URLComponents(string: text),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil
        else { return nil }
        return parts.url
    }

    static func canonical(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        components.host = components.host?.lowercased()
        components.scheme = nil
        components.fragment = nil
        if components.path == "/" { components.path = "" }
        let remaining = components.queryItems?.filter { item in
            let name = item.name.lowercased()
            return !name.hasPrefix("utm_") && !["fbclid", "gclid"].contains(name)
        }
        components.queryItems = remaining.flatMap { $0.isEmpty ? nil : $0.sorted { ($0.name, $0.value ?? "") < ($1.name, $1.value ?? "") } }
        return components.string ?? url.absoluteString
    }
}

private struct HNSearch: Decodable {
    let hits: [Hit]
    struct Hit: Decodable {
        let title: String?
        let url: String?
        let created_at_i: Int?
        let objectID: String
    }
}

private struct WorldSearch: Decodable {
    let articles: [Article]
    struct Article: Decodable {
        let url: String?
        let title: String?
        let seendate: String?
    }
}

enum FeedError: LocalizedError {
    case status(Int), response

    var errorDescription: String? {
        switch self {
        case .status(429): "Rate limited"
        case .status(let code): "Service returned HTTP \(code)"
        case .response: "Unexpected response"
        }
    }
}

enum Feed {
    static func decode(_ data: Data, from source: NewsSource) throws -> [Story] {
        let decoder = JSONDecoder()
        switch source {
        case .hackerNews:
            return try decoder.decode(HNSearch.self, from: data).hits.compactMap { hit in
                guard let title = cleanTitle(hit.title),
                      let identifier = Int(hit.objectID), identifier > 0,
                      let discussion = URL(string: "https://news.ycombinator.com/item?id=\(identifier)") else { return nil }
                return Story(title: title, url: Story.link(hit.url) ?? discussion,
                             date: hit.created_at_i.map { Date(timeIntervalSince1970: Double($0)) },
                             discussion: discussion, source: source)
            }
        case .worldNews:
            let format = DateFormatter()
            format.locale = Locale(identifier: "en_US_POSIX")
            format.timeZone = TimeZone(secondsFromGMT: 0)
            format.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
            return try decoder.decode(WorldSearch.self, from: data).articles.compactMap { article in
                guard let title = cleanTitle(article.title), let url = Story.link(article.url) else { return nil }
                return Story(title: title, url: url, date: article.seendate.flatMap(format.date(from:)),
                             discussion: nil, source: source)
            }
        }
    }

    static func search(_ source: NewsSource, query: String, days: Int) async throws -> [Story] {
        let (data, response) = try await URLSession.shared.data(for: source.request(query: query, days: days))
        guard let response = response as? HTTPURLResponse else { throw FeedError.response }
        guard (200..<300).contains(response.statusCode) else { throw FeedError.status(response.statusCode) }
        if data.isEmpty { return [] }
        return try decode(data, from: source)
    }

    static func merge(_ results: [NewsSource: [Story]], newest: Bool, only source: NewsSource?) -> [Story] {
        let ordered = NewsSource.allCases
            .filter { source == nil || source == $0 }
            .flatMap { results[$0] ?? [] }
        var seen: Set<String> = []
        let unique = ordered.filter { seen.insert($0.id).inserted }
        if !newest { return unique }
        return unique.sorted { ($0.date ?? .distantPast, $0.title) > ($1.date ?? .distantPast, $1.title) }
    }

    private static func cleanTitle(_ text: String?) -> String? {
        guard let title = text?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }
        return title
    }
}

private struct FeedOutcome: Sendable {
    let source: NewsSource
    let stories: [Story]
    let note: String
}

@MainActor
private final class SearchState: ObservableObject {
    @Published private(set) var statuses: [NewsSource: String] = [:]
    @Published private(set) var results: [NewsSource: [Story]] = [:]
    @Published private(set) var activeQuery = ""
    @Published private(set) var searching = false
    private var task: Task<Void, Never>?

    func search(_ input: String, days: Int) {
        let query = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.count <= 200 else { return }
        task?.cancel()
        activeQuery = query
        results = [:]
        statuses = Dictionary(uniqueKeysWithValues: NewsSource.allCases.map { ($0, "Searching…") })
        searching = true
        task = Task { [weak self] in
            await withTaskGroup(of: FeedOutcome.self) { group in
                for source in NewsSource.allCases {
                    group.addTask {
                        do {
                            let found = try await Feed.search(source, query: query, days: days)
                            return FeedOutcome(source: source, stories: found, note: "\(found.count) found")
                        } catch let error as FeedError {
                            return FeedOutcome(source: source, stories: [], note: error.localizedDescription)
                        } catch let error as URLError where error.code == .timedOut {
                            return FeedOutcome(source: source, stories: [], note: "Timed out")
                        } catch {
                            return FeedOutcome(source: source, stories: [], note: "Unavailable")
                        }
                    }
                }
                for await outcome in group {
                    guard !Task.isCancelled else { return }
                    self?.statuses[outcome.source] = outcome.note
                    self?.results[outcome.source] = outcome.stories
                }
            }
            if !Task.isCancelled { self?.searching = false }
        }
    }
}

private struct NewsWindow: View {
    @ObservedObject var state: SearchState
    @ViewState private var query = ""
    @ViewState private var days = 30
    @ViewState private var source: NewsSource?
    @ViewState private var newest = true
    private let ink = Color(red: 0.06, green: 0.10, blue: 0.15)
    private let card = Color(red: 0.10, green: 0.16, blue: 0.22)
    private let accent = Color(red: 0.50, green: 0.93, blue: 0.81)

    private var shown: [Story] { Feed.merge(state.results, newest: newest, only: source) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 13) {
                Image(systemName: "waveform.path")
                    .font(.system(size: 27, weight: .semibold))
                    .foregroundStyle(accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Signal Sift").font(.system(size: 30, weight: .bold, design: .rounded))
                    Text("Search Hacker News and the wider web press.").foregroundStyle(.secondary)
                }
                Spacer()
            }
            HStack(spacing: 10) {
                TextField("Search a topic", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { state.search(query, days: days) }
                Picker("Period", selection: $days) {
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                }
                .fixedSize()
                Button("Search") { state.search(query, days: days) }
                    .buttonStyle(.borderedProminent)
                    .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || query.count > 200)
            }
            if query.count > 200 {
                Text("Use 200 characters or fewer.").foregroundStyle(.secondary)
            }
            HStack(spacing: 16) {
                ForEach(NewsSource.allCases) { provider in
                    Text("\(provider.rawValue) · \(state.statuses[provider] ?? "Ready")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if state.searching { ProgressView().controlSize(.small) }
            }
            Divider()
            HStack {
                Picker("Source", selection: $source) {
                    Text("All sources").tag(Optional<NewsSource>.none)
                    ForEach(NewsSource.allCases) { Text($0.rawValue).tag(Optional($0)) }
                }
                .fixedSize()
                Picker("Sort", selection: $newest) {
                    Text("Newest").tag(true)
                    Text("Source order").tag(false)
                }
                .fixedSize()
                Spacer()
                if !state.activeQuery.isEmpty {
                    Text("\(shown.count) results for “\(state.activeQuery)”")
                        .lineLimit(1).foregroundStyle(.secondary)
                }
            }
            if shown.isEmpty {
                VStack(spacing: 8) {
                    Text(emptyTitle).font(.title3.bold())
                    Text(state.activeQuery.isEmpty ? "Try a topic like Switch 2, emulation, or Swift." :
                            "Try a wider time range, a shorter query, or another source.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(shown) { story in storyRow(story) }
                    }
                }
            }
        }
        .padding(24)
        .frame(minWidth: 680, minHeight: 440)
        .background(ink)
        .preferredColorScheme(.dark)
        .tint(accent)
    }

    private var emptyTitle: String {
        if state.searching { return "Looking for stories…" }
        return state.activeQuery.isEmpty ? "What are you curious about?" : "No stories to show"
    }

    private func storyRow(_ story: Story) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Link(story.title, destination: story.url)
                .font(.system(.headline)).foregroundStyle(accent)
            HStack {
                Text(story.url.host ?? story.source.rawValue)
                Text("· \(story.source.rawValue)")
                if let date = story.date {
                    Text(date, format: .dateTime.month().day().year())
                }
                Spacer()
                if let discussion = story.discussion, discussion != story.url {
                    Link("HN discussion", destination: discussion)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(card, in: RoundedRectangle(cornerRadius: 10))
    }
}

@MainActor
private final class NewsDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private let state = SearchState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let content = NSHostingController(rootView: NewsWindow(state: state))
        let newWindow = NSWindow(contentViewController: content)
        newWindow.title = "Signal Sift"
        newWindow.setContentSize(NSSize(width: 840, height: 620))
        newWindow.contentMinSize = NSSize(width: 680, height: 440)
        newWindow.center()
        newWindow.makeKeyAndOrderFront(nil)
        window = newWindow
        NSApp.activate(ignoringOtherApps: true)
        if CommandLine.arguments.contains("--smoke-test") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                guard newWindow.isVisible else { exit(1) }
                print("PASS: Signal Sift window opens")
                NSApp.terminate(nil)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct SignalSift {
    @MainActor static func main() async {
        let args = CommandLine.arguments
        if args.contains("--self-test") {
            do { try selfTest() } catch { fatalError("Self-test failed: \(error)") }
            return
        }
        if args.count > 2, args[1] == "--search" {
            let query = args.dropFirst(2).joined(separator: " ")
            for provider in NewsSource.allCases {
                do {
                    let stories = try await Feed.search(provider, query: query, days: 30)
                    print("\(provider.rawValue): \(stories.count) stories")
                    for story in stories.prefix(3) { print("  \(story.title) — \(story.url)") }
                } catch { print("\(provider.rawValue): \(error.localizedDescription)") }
            }
            return
        }
        let app = NSApplication.shared
        let delegate = NewsDelegate()
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }

    static func selfTest() throws {
        let hn = Data(#"{"hits":[{"title":"Example","url":"https://example.com/?utm_source=hn","created_at_i":1700000000,"objectID":"12"},{"title":"Ask HN","objectID":"13"}]}"#.utf8)
        let world = Data(#"{"articles":[{"title":"Duplicate","url":"http://example.com#other","seendate":"20250127T070000Z"},{"title":"Unsafe url","url":"javascript:alert(1)"}]}"#.utf8)
        let hnStories = try Feed.decode(hn, from: .hackerNews)
        let worldStories = try Feed.decode(world, from: .worldNews)
        precondition(hnStories.count == 2 && worldStories.count == 1 && worldStories[0].date != nil)
        precondition(hnStories[1].url == hnStories[1].discussion)
        precondition(Feed.merge([.hackerNews: hnStories, .worldNews: worldStories], newest: false, only: nil).count == 2)
        precondition(Feed.merge([.hackerNews: hnStories, .worldNews: worldStories], newest: true, only: .worldNews).count == 1)
        let request = NewsSource.hackerNews.request(query: "C++ & Swift", days: 7)
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
        precondition(query?.first?.value == "C++ & Swift" && request.url!.absoluteString.contains("C%2B%2B"))
        print("PASS: request encoding, provider parsing, safe links, dates, and deduplication")
    }
}
