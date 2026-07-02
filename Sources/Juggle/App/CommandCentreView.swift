import SwiftUI

/// Juggle's Settings — the macOS preferences idiom (⌘,). This is the standard
/// toolbar-tab Settings window users expect from ⌘, , not a free-floating panel:
/// `AppDelegate.showSettings` hosts it in a window whose toolbar style is
/// `.preference`, so each `tabItem` becomes a top toolbar pill and the window
/// resizes to the active tab. Every tab carries real, wired settings — there are
/// no placeholder tabs. The live "go to a terminal" surface is the separate
/// ⌘J switcher (`ProjectSwitcherView`), so Settings stays purely preferences.
///
/// `CommandCentreView` is kept as a thin alias so existing entry points compile
/// while the product name settles on "Settings".
typealias CommandCentreView = SettingsView

struct SettingsView: View {
    var body: some View {
        TabView {
            AppearanceSettings()
                .tabItem { Label("Appearance", systemImage: "paintbrush") }
            LayoutSettings()
                .tabItem { Label("Layouts", systemImage: "square.grid.2x2") }
            AttentionSettings()
                .tabItem { Label("Attention", systemImage: "bell") }
            TerminalSettings()
                .tabItem { Label("Terminal", systemImage: "terminal") }
            ShortcutsSettings()
                .tabItem { Label("Shortcuts", systemImage: "command") }
        }
        // One source of truth for the size (was hardcoded 520/360 and 520/396,
        // both mismatching the 540×430 host panel). The window in AppDelegate
        // sizes itself to this content via the .preference toolbar style.
        .frame(width: 540, height: 430)
        .scenePadding()
    }
}

private struct AppearanceSettings: View {
    @ObservedObject private var model = AppModel.shared

    var body: some View {
        Form {
            Section {
                if model.projects.isEmpty {
                    Text("Open a project to set its colour. Each project gets one accent; its worktrees render as shades of it.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.projects) { project in
                        HStack(spacing: 10) {
                            ColorSwatchPicker(currentName: project.colorName) { picked in
                                if let picked { model.recolor(projectId: project.id, colorName: picked) }
                            }
                            Text(project.displayName)
                                .font(.system(size: 13, weight: .medium))
                            Spacer()
                            Text(project.colorName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Project colours")
            } footer: {
                Text("Colour is identity: it tells you which repo a window belongs to. Pick a preset or a custom colour; the choice persists and re-tints every open window of that project.")
                    .font(.caption)
            }

            Section("Windows") {
                Slider(value: $model.preferences.titlebarTint) {
                    Text("Titlebar tint")
                } minimumValueLabel: {
                    Text("Subtle").font(.caption)
                } maximumValueLabel: {
                    Text("Bold").font(.caption)
                }
                Slider(value: $model.preferences.windowGap) {
                    Text("Window gap")
                } minimumValueLabel: {
                    Text("Tight").font(.caption)
                } maximumValueLabel: {
                    Text("Airy").font(.caption)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct LayoutSettings: View {
    @ObservedObject private var model = AppModel.shared

    var body: some View {
        Form {
            Section("Window grid") {
                HStack {
                    Text("Grid size")
                    Spacer()
                    GridSizePicker(columns: model.preferences.gridColumns, rows: model.preferences.gridRows) { columns, rows in
                        appController()?.setGrid(columns: columns, rows: rows)
                    }
                }
                Text("Terminals fill the cells; a new terminal takes the next free cell, and dragging a window snaps it into another cell. ⌘⌥G re-tiles.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Tile now") { appController()?.tileGrid() }
            }
        }
        .formStyle(.grouped)
    }
}

private struct TerminalSettings: View {
    @ObservedObject private var model = AppModel.shared

    var body: some View {
        Form {
            Section("Theme") {
                Picker("Terminal theme", selection: Binding(
                    get: { model.preferences.terminalTheme },
                    set: { newTheme in
                        model.preferences.terminalTheme = newTheme
                        if let fontSize = TerminalTheming.defaultFontSize(named: newTheme) {
                            model.preferences.terminalFontSize = fontSize
                        }
                    }
                )) {
                    ForEach(TerminalTheming.darkOptions, id: \.self) { Text("\($0)  ·  dark").tag($0) }
                    ForEach(TerminalTheming.lightOptions, id: \.self) { Text("\($0)  ·  light").tag($0) }
                }
                Text("Applies to every terminal immediately.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Text") {
                Stepper(value: $model.preferences.terminalFontSize, in: Preferences.terminalFontSizeRange, step: 1) {
                    HStack {
                        Text("Font size")
                        Spacer()
                        Text("\(Int(model.preferences.terminalFontSize)) pt")
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                Text("Terminal.app profiles use 11 pt for Basic and 12 pt for Clear Dark/Light. Applies to every terminal immediately.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Real settings for the signature attention behaviour (was a placeholder tab).
private struct AttentionSettings: View {
    @ObservedObject private var model = AppModel.shared
    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    var body: some View {
        Form {
            Section {
                Toggle("Show the notch attention strip", isOn: Binding(
                    get: { model.preferences.notchHUD },
                    set: { newValue in
                        model.preferences.notchHUD = newValue
                        (NSApp.delegate as? AppDelegate)?.applyNotchHUDPreference()
                    }
                ))
                Toggle("Breathing pulse when an agent needs you", isOn: $model.preferences.breathing)
                Toggle("Play a sound when an agent is blocked", isOn: $model.preferences.soundOnBlocked)
            } header: {
                Text("Signals")
            } footer: {
                Text("The notch strip hangs from the top of the screen and shows — across every project — what needs you (PR ready, blocked, error, done), so you catch it without staring at a window. ⌘J jumps to a terminal on demand. Attention is always behaviour on the project colour, never a competing palette.")
                    .font(.caption)
            }

            Section("How each state reads") {
                stateRow(color: CockpitStyle.nsAccent, title: "PR ready", detail: "A pull request went green — surfaced in the notch strip.")
                stateRow(color: CockpitStyle.nsAccent, title: "Blocked", detail: "Steady slow breathing — needs your input.")
                stateRow(color: CockpitStyle.nsAccent, title: "Done / idle", detail: "One soft pulse, then a calm steady accent.")
                stateRow(color: .systemRed, title: "Error", detail: "Breathing with a restrained warning edge.")
                stateRow(color: CockpitStyle.nsAccent, title: "Command finished", detail: "A single transient pulse for a long command.")
            }

            if reduceMotion {
                Section {
                    Label("Reduce Motion is on — Juggle shows a held, brighter accent instead of animating.",
                          systemImage: "figure.walk.motion")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func stateRow(color: NSColor, title: String, detail: String) -> some View {
        HStack(spacing: 10) {
            Circle().fill(Color(nsColor: color)).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

/// A read-only reference of Juggle's keyboard shortcuts (was a placeholder tab),
/// plus the first-run tour replay. Rebinding is a later unit; surfacing the real
/// bindings is the honest v1 (no dead "rebind keys" promise).
private struct ShortcutsSettings: View {
    private let shortcuts: [(keys: String, action: String)] = [
        ("⌘J", "Jump to a terminal (switcher)"),
        ("⌘0", "Toggle the control panel"),
        ("⌘O", "Open / add a project"),
        ("⌘N", "New terminal in the focused project"),
        ("⌘⌥G", "Tile every window into the grid"),
        ("⌘,", "Settings"),
        ("⌘W", "Close the focused window"),
        ("⌘M", "Minimise the focused window"),
    ]

    var body: some View {
        Form {
            Section("Keyboard") {
                ForEach(shortcuts, id: \.keys) { shortcut in
                    HStack {
                        Text(shortcut.action).font(.system(size: 12))
                        Spacer()
                        Text(shortcut.keys)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                Button {
                    replayOnboarding()
                } label: {
                    Label("Replay the first-run tour…", systemImage: "sparkles")
                }
            } footer: {
                Text("Walk through the seven-step introduction again.")
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
    }
}
