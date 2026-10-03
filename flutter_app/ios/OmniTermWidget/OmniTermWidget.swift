import SwiftUI
import WidgetKit

private struct Server: Decodable, Identifiable {
  let id: Int
  let name: String
  let host: String
  let status: String
  let health: Int
}

private struct OmniTermEntry: TimelineEntry {
  let date: Date
  let servers: [Server]
  let onlineCount: Int
}

private struct Provider: TimelineProvider {
  func placeholder(in context: Context) -> OmniTermEntry {
    OmniTermEntry(
      date: Date(),
      servers: [Server(id: 0, name: "OmniTerm host", host: "192.168.1.2", status: "online", health: 100)],
      onlineCount: 1
    )
  }

  func getSnapshot(in context: Context, completion: @escaping (OmniTermEntry) -> Void) {
    completion(load())
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<OmniTermEntry>) -> Void) {
    let entry = load()
    completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(15 * 60))))
  }

  private func load() -> OmniTermEntry {
    let defaults = UserDefaults(suiteName: "group.com.jetsetslow.omniterm")
    let raw = defaults?.string(forKey: "servers_json") ?? "[]"
    let servers = (try? JSONDecoder().decode([Server].self, from: Data(raw.utf8))) ?? []
    return OmniTermEntry(
      date: Date(),
      servers: servers,
      onlineCount: defaults?.integer(forKey: "online_count") ?? servers.filter { $0.status == "online" }.count
    )
  }
}

private struct OmniTermWidgetView: View {
  @Environment(\.widgetFamily) private var family
  let entry: OmniTermEntry

  private var rowLimit: Int {
    switch family {
    case .systemSmall: return 1
    case .systemMedium: return 3
    default: return 6
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack {
        Image(systemName: "terminal")
          .foregroundStyle(.cyan)
        Text("OmniTerm")
          .font(.headline)
        Spacer()
        Text("\(entry.onlineCount)/\(entry.servers.count)")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }

      if entry.servers.isEmpty {
        Spacer()
        Text("No saved hosts")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
      } else {
        ForEach(Array(entry.servers.prefix(rowLimit))) { server in
          Link(destination: URL(string: "omniterm://widget/server/\(server.id)")!) {
            HStack(spacing: 7) {
              Circle()
                .fill(server.status == "online" ? Color.green : Color.gray)
                .frame(width: 7, height: 7)
              VStack(alignment: .leading, spacing: 1) {
                Text(server.name.isEmpty ? server.host : server.name)
                  .font(.caption.bold())
                  .lineLimit(1)
                if family != .systemSmall {
                  Text(server.host)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
              }
              Spacer()
              Text("\(server.health)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(server.health >= 80 ? .green : .orange)
            }
          }
        }
        Spacer(minLength: 0)
      }
    }
    .padding(12)
    .background(Color.black.opacity(0.92))
  }
}

@main
struct OmniTermWidget: Widget {
  let kind = "OmniTermWidget"

  var body: some WidgetConfiguration {
    StaticConfiguration(kind: kind, provider: Provider()) { entry in
      OmniTermWidgetView(entry: entry)
    }
    .configurationDisplayName("OmniTerm Hosts")
    .description("See host status and open a terminal from the Home Screen.")
    .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
  }
}
