import DoppelKit
import SwiftUI

/// A keeper/other pair queued for side-by-side comparison (F8).
struct ComparePair: Identifiable {
    let keeper: FileRecord
    let other: FileRecord
    var id: String {
        "\(keeper.id)-\(other.id)"
    }
}

/// Side-by-side text compare with changed words highlighted — the trust builder (F8): shows two
/// files are the same document except for, e.g., a date. Diff is computed off the main actor via the
/// injected `diff` closure (reads + extracts both files); panes render normalized text.
struct CompareView: View {
    let pair: ComparePair
    let diff: (FileRecord, FileRecord) async -> TextDiff?
    @Environment(\.dismiss) private var dismiss
    @State private var result: TextDiff?
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Compare").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            if let result {
                if result.isIdentical {
                    Label("Text is identical", systemImage: "equal.circle")
                        .foregroundStyle(.secondary)
                }
                HStack(alignment: .top, spacing: 12) {
                    pane(pair.keeper, tokens: result.left, keeper: true)
                    Divider()
                    pane(pair.other, tokens: result.right, keeper: false)
                }
            } else if loaded {
                ContentUnavailableView(
                    "Can't compare these files",
                    systemImage: "doc.questionmark",
                    description: Text("One of them has no readable text (e.g. a scanned PDF).")
                )
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding()
        .frame(width: 720, height: 480)
        .task {
            result = await diff(pair.keeper, pair.other)
            loaded = true
        }
    }

    private func pane(_ file: FileRecord, tokens: [DiffToken], keeper: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(file.displayName, systemImage: keeper ? "star.fill" : "doc")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(keeper ? .primary : .secondary)
                .lineLimit(1).truncationMode(.middle)
            ScrollView {
                highlighted(tokens)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Renders the token stream as one wrapping Text, changed words on a yellow background.
    private func highlighted(_ tokens: [DiffToken]) -> Text {
        tokens.reduce(Text("")) { acc, token in
            var word = AttributedString(String(token.text) + " ")
            if token.changed { word.backgroundColor = .yellow.opacity(0.5) }
            return acc + Text(word)
        }
    }
}
