import SwiftUI

struct CompressorDashboardView: View {
    @ObservedObject var viewModel: CompressorViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 720, minHeight: 460)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Compressor")
                    .font(.system(size: 28, weight: .semibold))
                Text("Archive rarely used apps and restore them when needed.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Add App") {
                viewModel.selectAndArchive()
            }
            .keyboardShortcut("n", modifiers: [.command])
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.isWorking)
        }
        .padding(24)
    }

    private var content: some View {
        HStack(spacing: 0) {
            archivedAppsList
            Divider()
            progressPanel
        }
    }

    private var archivedAppsList: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Archived Apps")
                    .font(.headline)
                Spacer()
                Text("\(viewModel.apps.count)")
                    .foregroundStyle(.secondary)
            }

            if viewModel.apps.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("No archived apps yet.")
                        .font(.title3)
                    Text("Choose Add App to compress an app from Applications.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                List(viewModel.apps) { app in
                    ArchivedAppRow(app: app, viewModel: viewModel)
                        .listRowInsets(EdgeInsets(top: 10, leading: 8, bottom: 10, trailing: 8))
                }
                .listStyle(.inset)
            }
        }
        .padding(20)
        .frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
    }

    private var progressPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Current Work")
                    .font(.headline)

                HStack(alignment: .top, spacing: 12) {
                    if viewModel.isWorking {
                        SwiftUI.ProgressView()
                            .controlSize(.small)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text(viewModel.progressTitle)
                            .font(.body.weight(.medium))
                        Text(viewModel.progressDetail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Recoverable Space")
                    .font(.headline)
                Text(viewModel.formattedBytes(viewModel.totalRecoverableBytes))
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                Text("Space is fully reclaimed after Trash is emptied.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if let message = viewModel.lastMessage {
                MessageBox(text: message, color: .green)
            }

            if let error = viewModel.errorMessage {
                MessageBox(text: error, color: .red)
            }

            Spacer()

            Button("Open Archive Folder") {
                viewModel.openArchiveFolder()
            }
            .disabled(viewModel.isWorking)

            Button("Open Trash") {
                viewModel.openTrash()
            }
            .disabled(viewModel.isWorking)
        }
        .padding(20)
        .frame(minWidth: 300, idealWidth: 300, maxWidth: 300, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack {
            Button("Refresh") {
                viewModel.refresh()
            }
            .disabled(viewModel.isWorking)

            Spacer()

            Text("Archives are stored in Application Support.")
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

private struct ArchivedAppRow: View {
    let app: ManagedApp
    @ObservedObject var viewModel: CompressorViewModel

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(app.displayName)
                    .font(.body.weight(.medium))

                Text(app.originalPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 8) {
                    StatusBadge(text: statusText, color: statusColor)
                    if !viewModel.archiveExists(for: app) {
                        StatusBadge(text: "Archive missing", color: .red)
                    }
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 5) {
                Text(viewModel.formattedBytes(app.archiveSizeBytes))
                    .font(.callout.weight(.medium))
                Text("saved \(viewModel.formattedBytes(viewModel.savedBytes(for: app)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("Restore") {
                viewModel.restore(app)
            }
            .disabled(!viewModel.canRestore(app))
        }
        .padding(.vertical, 4)
    }

    private var statusText: String {
        switch app.status {
        case .archived:
            return "Archived"
        case .restoring:
            return "Restoring"
        case .restored:
            return "Restored"
        case .failed:
            return "Failed"
        }
    }

    private var statusColor: Color {
        switch app.status {
        case .archived:
            return .blue
        case .restoring:
            return .orange
        case .restored:
            return .green
        case .failed:
            return .red
        }
    }
}

private struct StatusBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(color)
            .background(color.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct MessageBox: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
