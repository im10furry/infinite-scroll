import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: PanelStore
    @StateObject private var agentStore = AgentWorkspaceStore()

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                CmdScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(store.panels.enumerated()), id: \.element.id) { index, panel in
                            RowView(
                                panel: panel,
                                fontSize: store.fontSize,
                                fontName: store.fontName,
                                rowHeight: store.rowHeight,
                                focusedCellID: store.focusedCellID,
                                agentRuns: agentStore.runs,
                                isNewlyInserted: panel.id == store.newlyAddedPanelID,
                                onClose: { store.removePanel(id: panel.id) }
                            )
                            .padding(
                                .bottom,
                                rowSpacing(after: panel, at: index, total: store.panels.count)
                            )
                        }
                    }
                    .padding(Theme.panelSpacing)
                }
                .background(Theme.background)

                if agentStore.isQueueVisible {
                    Divider()
                    AgentQueueView(agentStore: agentStore)
                        .frame(width: 330)
                }
            }

            if store.showHelp {
                HelpOverlay(isPresented: $store.showHelp)
            }

            if !agentStore.isQueueVisible {
                VStack {
                    HStack {
                        Button {
                            agentStore.isQueueVisible = true
                        } label: {
                            Label("Show Agent Queue", systemImage: "sidebar.right")
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        }
                        .buttonStyle(.bordered)
                        Spacer()
                    }
                    Spacer()
                }
                .padding(Theme.panelSpacing)
            }
        }
        .onAppear { agentStore.attach(to: store) }
    }

    private func rowSpacing(after panel: PanelModel, at index: Int, total: Int) -> CGFloat {
        guard index < total - 1 else { return 0 }
        return panel.isMaster ? Theme.masterSectionSpacing : Theme.panelSpacing
    }
}
