import AppKit
import SwiftUI

/// An interactive grid-size picker (like choosing a table size): hover to
/// preview, click to set columns × rows. Picking applies the grid immediately.
struct GridSizePicker: View {
    let columns: Int
    let rows: Int
    let onPick: (Int, Int) -> Void

    private let maxColumns = 5
    private let maxRows = 4
    @State private var hoverColumns = 0
    @State private var hoverRows = 0

    var body: some View {
        HStack(spacing: 10) {
            VStack(spacing: 3) {
                ForEach(0 ..< maxRows, id: \.self) { row in
                    HStack(spacing: 3) {
                        ForEach(0 ..< maxColumns, id: \.self) { column in
                            cell(column: column, row: row)
                        }
                    }
                }
            }
            .onHover { inside in
                if !inside { hoverColumns = 0; hoverRows = 0 }
            }
            Text("\(hoverColumns > 0 ? hoverColumns : columns) × \(hoverRows > 0 ? hoverRows : rows)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(CockpitStyle.secondaryText)
                .frame(width: 36, alignment: .leading)
        }
    }

    private func cell(column: Int, row: Int) -> some View {
        let active = hoverColumns > 0
            ? (column < hoverColumns && row < hoverRows)
            : (column < columns && row < rows)
        // Single-accent rule (U8): the active grid cells must use the app accent,
        // not `Color.accentColor` (the user's system highlight, default blue),
        // which renders as a second accent competing with the project colour.
        return RoundedRectangle(cornerRadius: 2.5)
            .fill(active ? CockpitStyle.accent : Color.white.opacity(0.16))
            .frame(width: 15, height: 11)
            .onHover { inside in
                if inside { hoverColumns = column + 1; hoverRows = row + 1 }
            }
            .onTapGesture { onPick(column + 1, row + 1) }
    }
}

/// A swatch button that opens a popover with the curated palette AND a fully
/// inline custom-colour editor (hue spectrum + shade row), so the user isn't
/// limited to the presets. Custom colours are stored as `#RRGGBB`.
///
/// Why inline and not SwiftUI's `ColorPicker`: that control opens the shared
/// system `NSColorPanel`, which takes key focus and dismisses this transient
/// popover — orphaning its `onChange` binding so picks in the lingering panel
/// never applied and the user had to click again. Keeping every control in one
/// popover means selecting a hue *is* the action: it previews live and applies
/// on release, no second click, no stray system window.
struct ColorSwatchPicker: View {
    let currentName: String?
    var allowClear: Bool = false
    let onPick: (String?) -> Void

    @State private var showing = false
    @State private var hue: Double = 0
    @State private var preview: Color?   // live thumb colour while editing

    private var currentColor: NSColor { RepoColor.nsColor(for: currentName) }
    private var visibleColor: Color { preview ?? Color(nsColor: currentColor) }

    var body: some View {
        Button { showing.toggle() } label: {
            RoundedRectangle(cornerRadius: 5)
                .fill(visibleColor)
                .frame(width: 16, height: 16)
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.white.opacity(0.2)))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Palette")
                    .font(.system(size: 10, weight: .semibold)).textCase(.uppercase)
                    .kerning(0.6).foregroundStyle(.secondary)
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(24), spacing: 8), count: 5), spacing: 8) {
                    ForEach(RepoColor.palette, id: \.name) { color in
                        Button {
                            preview = nil
                            onPick(color.name)
                            showing = false
                        } label: {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color(nsColor: color.nsColor))
                                .frame(width: 22, height: 22)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .strokeBorder(.white, lineWidth: currentName == color.name ? 2 : 0)
                                )
                        }
                        .buttonStyle(.plain)
                        .help(color.name)
                    }
                }

                Divider()

                Text("Custom")
                    .font(.system(size: 10, weight: .semibold)).textCase(.uppercase)
                    .kerning(0.6).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(visibleColor)
                        .frame(width: 26, height: 22)
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.18)))
                    Text("Drag the spectrum or pick a shade — release applies.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                HueSpectrumSlider(hue: $hue) { committed in
                    // Selecting a hue IS the action — apply on release, no 2nd click.
                    let color = Color(hue: hue, saturation: 0.72, brightness: 0.92)
                    preview = color
                    if committed { onPick(NSColor(color).hexString) }
                }
                HStack(spacing: 6) {
                    ForEach(Array(shades.enumerated()), id: \.offset) { _, shade in
                        Button {
                            preview = shade
                            onPick(NSColor(shade).hexString)
                        } label: {
                            RoundedRectangle(cornerRadius: 5)
                                .fill(shade)
                                .frame(height: 18)
                                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.white.opacity(0.15)))
                        }
                        .buttonStyle(.plain)
                    }
                }

                if allowClear {
                    Divider()
                    Button("Use project color") { preview = nil; onPick(nil); showing = false }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .frame(width: 208)
            .onAppear {
                preview = nil
                hue = currentColor.hueComponentSafe
            }
        }
    }

    /// Four brightness/saturation shades of the live hue, so a custom colour can
    /// be nudged lighter/darker without a second control.
    private var shades: [Color] {
        [(0.55, 1.0), (0.72, 0.92), (0.85, 0.78), (0.95, 0.6)].map {
            Color(hue: hue, saturation: $0.0, brightness: $0.1)
        }
    }
}

/// A horizontal hue spectrum the user drags to pick any hue. Reports continuous
/// previews while dragging and a committed value on release (and on tap), so a
/// single gesture both previews and applies.
struct HueSpectrumSlider: View {
    @Binding var hue: Double
    /// `committed` is false during a live drag, true on release / tap.
    let onChange: (_ committed: Bool) -> Void

    private let spectrum: [Color] = stride(from: 0.0, through: 1.0, by: 1.0 / 12.0)
        .map { Color(hue: $0, saturation: 0.72, brightness: 0.92) }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                LinearGradient(colors: spectrum, startPoint: .leading, endPoint: .trailing)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.15)))
                Circle()
                    .fill(.white)
                    .frame(width: 14, height: 14)
                    .overlay(Circle().strokeBorder(.black.opacity(0.25)))
                    .shadow(radius: 1)
                    .offset(x: max(0, min(geo.size.width - 14, hue * geo.size.width - 7)))
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        hue = max(0, min(1, value.location.x / geo.size.width))
                        onChange(false)
                    }
                    .onEnded { value in
                        hue = max(0, min(1, value.location.x / geo.size.width))
                        onChange(true)
                    }
            )
        }
        .frame(height: 18)
    }
}
