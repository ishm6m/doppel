import DoppelCore
import DoppelKit
import SwiftUI

/// Native Settings scene (F11). Tabs: Detection (threshold, OCR), Ignore List (review/reset), About.
/// Settings persist to UserDefaults via @AppStorage and feed the next scan through `DetectionSettings`.
/// ponytail: the General (file-type scopes) and Model (embedding provider) tabs were dropped — both were
/// entirely disabled placeholders (images are V2; no model is pinned yet). Re-add them when those ship.
struct SettingsView: View {
    var body: some View {
        TabView {
            DetectionSettingsTab()
                .tabItem { Label("Detection", systemImage: "scope") }
            IgnoreListSettings()
                .tabItem { Label("Ignore List", systemImage: "hand.raised") }
            AboutSettings()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 480)
    }
}

private struct DetectionSettingsTab: View {
    @AppStorage(SettingsKey.nearDupThreshold) private var threshold = 0.85
    @AppStorage(SettingsKey.ocrEnabled) private var ocrEnabled = false

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading) {
                    LabeledContent("Near-duplicate sensitivity") {
                        Text(threshold.formatted(.percent.precision(.fractionLength(0))))
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                    // Higher threshold = stricter (fewer, more confident near-dup matches).
                    Slider(value: $threshold, in: 0.5 ... 0.99, step: 0.01) {
                        Text("Near-duplicate sensitivity")
                    } minimumValueLabel: {
                        Text("Loose").font(.caption)
                    } maximumValueLabel: {
                        Text("Strict").font(.caption)
                    }
                    Text("Higher is stricter: only very similar documents are grouped.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                Toggle("Run OCR on scanned PDFs", isOn: $ocrEnabled)
                Text("Reads text from image-only PDFs so they can be compared. Slower; off by default.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped).padding(.vertical, 8).frame(height: 280)
    }
}

private struct IgnoreListSettings: View {
    @Environment(AppEnvironment.self) private var env
    @State private var pairCount = 0
    @State private var confirmReset = false

    var body: some View {
        Form {
            LabeledContent("Remembered \"not duplicates\"", value: "\(pairCount) pair\(pairCount == 1 ? "" : "s")")
            Button("Reset Ignore List", role: .destructive) { confirmReset = true }
                .disabled(pairCount == 0)
            Text("Groups you marked \"not duplicates\" won't reappear. Resetting lets them surface again.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped).padding(.vertical, 8).frame(height: 220)
        .task { pairCount = await env.scanService.ignoredPairCount() }
        .confirmationDialog("Reset the ignore list?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) {
                Task {
                    try? await env.scanService.clearIgnoredList()
                    pairCount = await env.scanService.ignoredPairCount()
                }
            }
        }
    }
}

private struct AboutSettings: View {
    var body: some View {
        Form {
            HStack {
                Spacer()
                Image("DoppelLogo")
                    .resizable().scaledToFit()
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .accessibilityLabel("\(AppInfo.productName) logo")
                Spacer()
            }
            LabeledContent("Name", value: AppInfo.productName)
            LabeledContent("Version", value: AppInfo.version)
            LabeledContent("Website") {
                // SAFETY: static, well-formed literal URL.
                Link("getdoppel.vercel.app", destination: URL(string: "https://getdoppel.vercel.app")!)
            }
            Text("100% offline. No file, name, path, or fingerprint ever leaves your Mac.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped).padding(.vertical, 8).frame(height: 300)
    }
}
