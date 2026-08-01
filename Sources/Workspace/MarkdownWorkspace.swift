import AppKit
import SwiftUI

struct MarkdownWorkspace: View {
    @ObservedObject var syncCoordinator: DocumentSyncCoordinator
    @ObservedObject var model: WorkspaceModel
    let fileName: String

    var body: some View {
        ZStack {
            MaterialView()
                .ignoresSafeArea()
            Color(nsColor: AppTheme.background)
                .opacity(
                    NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
                        ? 1
                        : AppTheme.backgroundOverlayOpacity
                )
                .ignoresSafeArea()
            VStack(spacing: 0) {
                editorSurface
                Divider().overlay(Color(nsColor: AppTheme.separator))
                statusBar
            }
        }
        .preferredColorScheme(.dark)
        .frame(minWidth: 680, minHeight: 440)
    }

    @ViewBuilder
    private var editorSurface: some View {
        if model.isSplit {
            HSplitView {
                editor(pane: model.primaryPane)
                editor(pane: model.secondaryPane)
            }
        } else {
            editor(pane: model.primaryPane)
        }
    }

    private func editor(pane: EditorPaneModel) -> some View {
        LivePreviewTextView(
            sourceBuffer: syncCoordinator.sourceBuffer,
            pane: pane,
            sourceMode: model.sourceMode,
            fontSize: model.fontSize,
            newlineStyle: syncCoordinator.format.dominantNewline,
            documentURL: syncCoordinator.fileURL,
            onBecameActive: {
                model.activate(pane)
            }
        )
        .id(pane.id)
        .frame(minWidth: 240, maxWidth: .infinity)
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            Text(syncCoordinator.fileURL?.lastPathComponent ?? fileName)
                .lineLimit(1)
            if let statusPresentation {
                Label(
                    statusPresentation.message,
                    systemImage: statusPresentation.systemImage
                )
                .foregroundStyle(statusColor(for: statusPresentation.tone))
                .accessibilityLabel(
                    "Synchronization status: \(statusPresentation.message)"
                )
                if let action = statusPresentation.primaryAction {
                    Button(action.label) {
                        performStatusAction(action)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color(nsColor: AppTheme.accent))
                    .accessibilityLabel(action.label)
                }
                if statusPresentation.offersSaveAs {
                    Button("Save As…") {
                        performStatusAction(.saveAs)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color(nsColor: AppTheme.accent))
                    .accessibilityLabel("Save As…")
                }
                if statusPresentation.offersLocalRevisionRestore {
                    Button("Restore Local Revision") {
                        syncCoordinator.restoreLatestRecovery()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color(nsColor: AppTheme.accent))
                    .accessibilityLabel("Restore Local Revision")
                }
                if statusPresentation.offersRawRecoveryDiscard {
                    Button("Discard Raw Recovery & Resume") {
                        syncCoordinator.resumeSynchronization()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color(nsColor: AppTheme.failure))
                    .accessibilityLabel(
                        "Discard Raw Recovery and Resume Synchronization"
                    )
                }
            }
            Spacer()
            PanePositionStatus(pane: model.activePane)
                .id(model.activePaneID)
            Text(syncCoordinator.format.encoding.displayName)
            Text(syncCoordinator.format.dominantNewline.rawValue.uppercased())
            Button {
                model.toggleSourceMode()
            } label: {
                Image(
                    systemName: model.sourceMode
                        ? "eye"
                        : "chevron.left.forwardslash.chevron.right"
                )
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color(nsColor: AppTheme.accent))
            .help(model.sourceMode ? "Use Live Preview" : "Use Source Mode")
            .accessibilityLabel("Toggle Source Mode")
            Button {
                model.toggleSplit()
            } label: {
                Image(systemName: model.isSplit ? "rectangle" : "rectangle.split.2x1")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color(nsColor: AppTheme.accent))
            .help(model.isSplit ? "Close Split" : "Split Editor")
            .accessibilityLabel("Toggle Split")
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .foregroundStyle(Color(nsColor: AppTheme.mutedForeground))
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(
            Color(nsColor: AppTheme.background)
                .opacity(AppTheme.statusBarOverlayOpacity)
        )
    }

    private var statusPresentation: SynchronizationStatusPresentation? {
        let snapshot = syncCoordinator.statusSnapshot
        return snapshot.presentedState.flatMap {
            SynchronizationStatusPresentation.make(
                for: $0,
                failureRequiresSaveAs: snapshot.failureRequiresSaveAs,
                recoveryMigrationIsPending:
                    snapshot.recoveryMigrationIsPending,
                recoveryRetryAvailable: snapshot.recoveryRetryAvailable,
                rawRecoveryURL: snapshot.rawRecoveryURL,
                hasLocalRecovery: snapshot.hasLocalRecovery
            )
        }
    }

    private func statusColor(
        for tone: SynchronizationStatusPresentation.Tone
    ) -> Color {
        switch tone {
        case .failure:
            Color(nsColor: AppTheme.failure)
        case .accent:
            Color(nsColor: AppTheme.accent)
        }
    }

    private func performStatusAction(
        _ action: SynchronizationStatusPresentation.Action
    ) {
        switch action {
        case .restoreLocalRevision:
            syncCoordinator.restoreLatestRecovery()
        case .saveAs:
            NSApp.sendAction(
                #selector(NSDocument.saveAs(_:)),
                to: nil,
                from: nil
            )
        case .retrySynchronization:
            syncCoordinator.retrySynchronization()
        case .retryRecoveryMigration:
            syncCoordinator.retryRecoveryMigration()
        case .showRecoveryFile(let url):
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}

private struct PanePositionStatus: View {
    @ObservedObject var pane: EditorPaneModel

    var body: some View {
        if pane.isPositionPending {
            Text("Indexing")
        } else {
            Text("Ln \(pane.line), Col \(pane.column)")
        }
    }
}

extension TextEncoding {
    fileprivate var displayName: String {
        switch self {
        case .utf8: "UTF-8"
        case .utf8WithBOM: "UTF-8 BOM"
        case .utf16LittleEndian: "UTF-16 LE"
        case .utf16BigEndian: "UTF-16 BE"
        }
    }
}
