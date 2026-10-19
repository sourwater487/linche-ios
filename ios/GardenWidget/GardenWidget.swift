import SwiftUI
import WidgetKit
import CoreText

struct GardenEntry: TimelineEntry {
    let date: Date
    let text: String
    let excerpt: GardenExcerpt?

    init(date: Date, text: String, excerpt: GardenExcerpt? = nil) {
        self.date = date; self.text = text; self.excerpt = excerpt
    }

    init(date: Date, sentence: GardenSentence?, fallback: String) {
        self.init(date: date, text: sentence?.text ?? fallback, excerpt: sentence?.excerpt)
    }

    var accessibilityText: String {
        [text, excerpt?.text, excerpt?.comment, excerpt?.source]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "。")
    }
}

struct GardenProvider: TimelineProvider {
    func placeholder(in context: Context) -> GardenEntry {
        GardenEntry(date: Date(), text: "Garden")
    }

    func getSnapshot(in context: Context, completion: @escaping (GardenEntry) -> Void) {
        let now = Date()
        completion(GardenEntry(date: now, sentence: GardenStore.cached()?.current(at: now),
            fallback: context.isPreview ? "Garden" : "打开 Lin & Che\n让 Garden 来到这里"))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<GardenEntry>) -> Void) {
        Task {
            let fetched = try? await GardenStore.fetch()
            let snapshot = fetched ?? GardenStore.cached()
            let now = Date()
            var entries = [GardenEntry(date: now, sentence: snapshot?.current(at: now), fallback: "打开 Lin & Che\n同步 Garden")]
            if let snapshot, snapshot.validUntil > now {
                entries += snapshot.entries.filter { $0.date > now && $0.date < snapshot.validUntil }
                    .map { GardenEntry(date: $0.date, text: $0.text, excerpt: $0.excerpt) }
                // Never keep yesterday's sentence indefinitely when offline or signed out.
                entries.append(GardenEntry(date: snapshot.validUntil, text: "打开 Lin & Che\n同步 Garden"))
            }
            completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(30 * 60))))
        }
    }
}

private enum GardenFont {
    static let register: Void = {
        // Read the one font already bundled in the containing app; don't add a
        // second 32 MB copy to the widget or download assets at render time.
        let app = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
        let url = app.appendingPathComponent("KingHwaOldSong.ttf")
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }()
}

struct GardenWidgetView: View {
    let entry: GardenEntry
    @Environment(\.widgetFamily) private var family
    init(entry: GardenEntry) { self.entry = entry; _ = GardenFont.register }

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("GARDEN")
                    .font(.custom("KingHwaOldSong", fixedSize: 9))
                    .tracking(2)
                    .fixedSize()
                Rectangle()
                    .frame(width: 18, height: 0.5)
                Spacer(minLength: 0)
            }
            .opacity(0.6)
            .accessibilityHidden(true)

            Text(entry.text)
                .font(.custom("KingHwaOldSong", fixedSize: entry.text.count > 45 ? 14 : 16))
                .multilineTextAlignment(.leading)
                .lineSpacing(3)
                .lineLimit(5)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .layoutPriority(1)

            HStack {
                Spacer(minLength: 0)
                Text("Che")
                    .font(.custom("KingHwaOldSong", fixedSize: 11))
                    .tracking(0.8)
                    .fixedSize()
            }
            .opacity(0.65)
            .accessibilityHidden(true)
        }
        .foregroundStyle(.primary)
        .padding(16)
        .widgetURL(URL(string: "linche://garden"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.text)
    }

    private var mediumContent: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 9) {
                Text("GARDEN").tracking(2).fixedSize()
                Rectangle().frame(height: 0.5).opacity(0.35)
                Text("摘录 · 随记").tracking(1).fixedSize()
            }
            .font(.custom("KingHwaOldSong", fixedSize: 9))
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)

            GeometryReader { geometry in
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(entry.text)
                            .font(.custom("KingHwaOldSong", fixedSize: 15))
                            .lineSpacing(2)
                            .lineLimit(5)
                            .minimumScaleFactor(0.85)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .layoutPriority(1)
                        Spacer(minLength: 0)
                        Text("Che")
                            .font(.custom("KingHwaOldSong", fixedSize: 11))
                            .tracking(0.8)
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: max(0, (geometry.size.width - 25) * 0.37), height: geometry.size.height, alignment: .topLeading)

                    Rectangle().fill(Color.primary.opacity(0.15)).frame(width: 0.5)

                    VStack(alignment: .leading, spacing: 5) {
                        if let excerpt = entry.excerpt, !excerpt.text.isEmpty {
                            Text("“" + excerpt.text + "”")
                                .font(.custom("KingHwaOldSong", fixedSize: 13))
                                .lineSpacing(2)
                                .lineLimit(3)
                                .minimumScaleFactor(0.9)
                                .layoutPriority(1)
                            if let comment = excerpt.comment, !comment.isEmpty {
                                Text(comment)
                                    .font(.custom("KingHwaOldSong", fixedSize: 11))
                                    .lineSpacing(1)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Spacer(minLength: 0)
                            if let source = excerpt.source, !source.isEmpty {
                                Text("— " + source)
                                    .font(.custom("KingHwaOldSong", fixedSize: 9))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        } else {
                            Text("“")
                                .font(.custom("KingHwaOldSong", fixedSize: 32))
                                .foregroundStyle(.tertiary)
                            Text("等待一页书摘")
                                .font(.custom("KingHwaOldSong", fixedSize: 12))
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
        }
        .multilineTextAlignment(.leading)
        .foregroundStyle(.primary)
        .padding(14)
        .widgetURL(URL(string: "linche://garden"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.accessibilityText)
    }

    @ViewBuilder private var familyContent: some View {
        if family == .systemMedium { mediumContent } else { content }
    }

    var body: some View {
        if #available(iOSApplicationExtension 17.0, *) {
            familyContent.containerBackground(for: .widget) { Color.clear }
        } else {
            familyContent.background(Color.clear)
        }
    }
}

@main
struct GardenWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: GardenStore.kind, provider: GardenProvider()) { GardenWidgetView(entry: $0) }
            .configurationDisplayName("Garden")
            .description("他在这个时刻写给你的话。")
            .supportedFamilies([.systemSmall, .systemMedium])
            .contentMarginsDisabled()
    }
}
