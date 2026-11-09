import ActivityKit
import SwiftUI
import WidgetKit

@main
struct VoiceActivityBundle: WidgetBundle {
    var body: some Widget { VoiceActivity() }
}

struct VoiceActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: VoiceActivityAttributes.self) { context in
            HStack(spacing: 14) {
                Image(systemName: "waveform").font(.title2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(context.attributes.name).font(.headline)
                    Text(context.state.phase).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)
            .activityBackgroundTint(.black)
            .activitySystemActionForegroundColor(.white)
            .foregroundStyle(.white)
            .widgetURL(URL(string: "taptype://home"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "waveform").font(.title2).padding(.leading, 8)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 4) {
                        Text(context.state.phase).font(.headline)
                        Text(context.state.phase == "Ready" ? "Microphone on · Idle audio discarded" : context.attributes.name).font(.caption).foregroundStyle(.secondary)
                    }.padding(.bottom, 8)
                }
            } compactLeading: {
                Image(systemName: "waveform").font(.system(size: 18, weight: .semibold))
                    .accessibilityLabel("\(context.attributes.name), \(context.state.phase)")
            } compactTrailing: {
                EmptyView()
            } minimal: {
                Image(systemName: "waveform")
            }
            .keylineTint(.white.opacity(0.25))
            .widgetURL(URL(string: "taptype://home"))
        }
    }
}
