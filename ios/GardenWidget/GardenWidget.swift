import SwiftUI
import WidgetKit
import CoreText

struct GardenEntry: TimelineEntry {
    let date: Date
    let text: String
}

struct GardenProvider: TimelineProvider {
    func placeholder(in context: Context) -> GardenEntry {
        GardenEntry(date: Date(), text: "Garden")
    }

    func getSnapshot(in context: Context, completion: @escaping (GardenEntry) -> Void) {
        let now = Date()
        completion(GardenEntry(date: now, text: context.isPreview ? "Garden" : GardenStore.cached()?.current(at: now)?.text ?? "打开 Lin & Che\n让 Garden 来到这里"))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<GardenEntry>) -> Void) {
        Task {
            let fetched = try? await GardenStore.fetch()
            let snapshot = fetched ?? GardenStore.cached()
            let now = Date()
            var entries = [GardenEntry(date: now, text: snapshot?.current(at: now)?.text ?? "打开 Lin & Che\n同步 Garden")]
            if let snapshot, snapshot.validUntil > now {
                entries += snapshot.entries.filter { $0.date > now && $0.date < snapshot.validUntil }
                    .map { GardenEntry(date: $0.date, text: $0.text) }
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

    var body: some View {
        if #available(iOSApplicationExtension 17.0, *) {
            content.containerBackground(for: .widget) { Color.clear }
        } else {
            content.background(Color.clear)
        }
    }
}

@main
struct GardenWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: GardenStore.kind, provider: GardenProvider()) { GardenWidgetView(entry: $0) }
            .configurationDisplayName("Garden")
            .description("他在这个时刻写给你的话。")
            .supportedFamilies([.systemSmall])
            .contentMarginsDisabled()
    }
}
