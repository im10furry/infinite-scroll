import AppKit
import SwiftUI

struct SettingsView: View {
    /// Draws the same form without the fixed window frame when it is hosted in
    /// the right sidebar instead of the Settings scene.
    var embedded: Bool = false
    @EnvironmentObject var store: PanelStore
    @State private var cliInstalled: Bool = CLIInstaller.isInstalled()
    @State private var cliBusy: Bool = false
    @State private var cliError: String?

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Font", selection: $store.fontName) {
                    ForEach(PanelStore.availableMonospacedFonts, id: \.self) { name in
                        Text(name)
                            .font(.custom(name, size: 13))
                            .tag(name)
                    }
                }

                Stepper(value: $store.fontSize, in: 8...32, step: 1) {
                    Text("Size: \(Int(store.fontSize))pt")
                }
            }

            Section("Terminal") {
                Picker("Scrollback", selection: $store.scrollbackLimit) {
                    ForEach(TmuxManager.historyLimitOptions, id: \.self) { limit in
                        Text("\(limit.formatted()) lines").tag(limit)
                    }
                }

                Text("Applies to every terminal and to the tmux sessions backing them. Larger values use more memory per terminal.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            Section("Layout") {
                Stepper(
                    value: $store.rowHeight,
                    in: PanelStore.minRowHeight...PanelStore.maxRowHeight,
                    step: 25
                ) {
                    Text("Row height: \(Int(store.rowHeight))px")
                }

                Slider(
                    value: $store.rowHeight,
                    in: PanelStore.minRowHeight...PanelStore.maxRowHeight,
                    step: 25
                )
            }

            Section("Navigation") {
                HStack {
                    Text("Workspace scroll speed")
                    Spacer()
                    Text("\(Int((store.commandScrollSpeed * 100).rounded()))%")
                        .foregroundColor(.secondary)
                }

                Slider(
                    value: $store.commandScrollSpeed,
                    in: PanelStore.minCommandScrollSpeed...PanelStore.maxCommandScrollSpeed,
                    step: 0.25
                )

                Text("Applies only when holding Command while scrolling between rows.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            Section("Shell command") {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(cliInstalled ? "Installed at \(CLIInstaller.installTarget)" : "Not installed")
                            .font(.system(size: 12))
                        Text("Lets AI agents and scripts read and manipulate cells from a terminal. Run 'infinite-scroll --help' to see commands.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let cliError {
                            Text(cliError)
                                .font(.system(size: 11))
                                .foregroundColor(Theme.closeButton)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer()
                    if cliInstalled {
                        Button("Uninstall") {
                            cliBusy = true
                            cliError = nil
                            DispatchQueue.global(qos: .userInitiated).async {
                                let ok = CLIInstaller.uninstall()
                                DispatchQueue.main.async {
                                    cliInstalled = CLIInstaller.isInstalled()
                                    if !ok {
                                        cliError = "Uninstall failed. Check permissions for \(CLIInstaller.installTarget)."
                                    }
                                    cliBusy = false
                                }
                            }
                        }
                        .disabled(cliBusy)
                    } else {
                        Button("Install Shell Command") {
                            cliBusy = true
                            cliError = nil
                            DispatchQueue.global(qos: .userInitiated).async {
                                let ok = CLIInstaller.install()
                                DispatchQueue.main.async {
                                    cliInstalled = CLIInstaller.isInstalled()
                                    if !ok {
                                        cliError = "Install failed. Check permissions for \(CLIInstaller.installTarget)."
                                    }
                                    cliBusy = false
                                }
                            }
                        }
                        .disabled(cliBusy)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: embedded ? nil : 480, height: embedded ? nil : 570)
        .scrollContentBackground(embedded ? .hidden : .automatic)
        .background(embedded ? Theme.panelBackground : Color.clear)
        .onAppear { cliInstalled = CLIInstaller.isInstalled() }
    }
}
