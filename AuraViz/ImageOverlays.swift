import AppKit
import ImageIO
import os
import SwiftUI
import UniformTypeIdentifiers

/// An uploaded image laid over the stage: a logo, artwork or a sponsor slide.
struct ImageOverlay: Identifiable, Codable, Equatable {
    static let sizeRange: ClosedRange<Double> = 0.05...1
    static let opacityRange: ClosedRange<Double> = 0...1
    static let pulseRange: ClosedRange<Double> = 0...1
    static let defaultSize = 0.35
    static let defaultOpacity = 1.0
    static let defaultPulse = 0.5
    /// Gap between a corner image and the stage edge, as a fraction of the
    /// stage's shorter side.
    static let cornerMargin: CGFloat = 0.04

    var id = UUID()
    /// The file name it was added from, for the controls.
    var name: String
    /// The stored copy in the overlays folder.
    var fileName: String
    var isVisible = true
    var placement: ImageOverlayPlacement = .center
    /// How much of the stage (inside the margins) the image may fill on each
    /// axis, keeping its aspect ratio. Ignored by `.fill`.
    var size = ImageOverlay.defaultSize
    var opacity = ImageOverlay.defaultOpacity
    var blend: ImageOverlayBlend = .normal
    /// How far the image punches up on each beat, scaled by beat reactivity.
    var pulse = ImageOverlay.defaultPulse
}

/// Where an overlay image sits on the stage.
enum ImageOverlayPlacement: String, CaseIterable, Identifiable, Codable {
    case center = "Center"
    case topLeft = "Top Left"
    case topRight = "Top Right"
    case bottomLeft = "Bottom Left"
    case bottomRight = "Bottom Right"
    case fill = "Fill Stage"

    var id: Self { self }

    /// Fill covers the whole stage, so the size doesn't apply.
    var isSized: Bool { self != .fill }

    /// The image's frame on a stage of `stage` size: fitted into `size` of the
    /// stage inside the margins and pinned to its spot, or covering the whole
    /// stage (cropped) for `.fill`.
    func frame(forImage image: CGSize, size: Double, in stage: CGSize) -> CGRect {
        guard image.width > 0, image.height > 0, stage.width > 0, stage.height > 0 else { return .zero }
        if self == .fill {
            let fit = max(stage.width / image.width, stage.height / image.height)
            let width = image.width * fit
            let height = image.height * fit
            return CGRect(x: (stage.width - width) / 2, y: (stage.height - height) / 2, width: width, height: height)
        }
        let margin = min(stage.width, stage.height) * ImageOverlay.cornerMargin
        let box = CGSize(width: (stage.width - 2 * margin) * CGFloat(size), height: (stage.height - 2 * margin) * CGFloat(size))
        let fit = min(box.width / image.width, box.height / image.height)
        let width = image.width * fit
        let height = image.height * fit
        let left = margin
        let right = stage.width - margin - width
        let top = margin
        let bottom = stage.height - margin - height
        switch self {
        case .center, .fill:
            return CGRect(x: (stage.width - width) / 2, y: (stage.height - height) / 2, width: width, height: height)
        case .topLeft: return CGRect(x: left, y: top, width: width, height: height)
        case .topRight: return CGRect(x: right, y: top, width: width, height: height)
        case .bottomLeft: return CGRect(x: left, y: bottom, width: width, height: height)
        case .bottomRight: return CGRect(x: right, y: bottom, width: width, height: height)
        }
    }
}

/// How an overlay image combines with the visualizer beneath it.
enum ImageOverlayBlend: String, CaseIterable, Identifiable, Codable {
    case normal = "Normal"
    case screen = "Screen"
    case add = "Add"

    var id: Self { self }

    var blendMode: BlendMode {
        switch self {
        case .normal: return .normal
        case .screen: return .screen
        case .add: return .plusLighter
        }
    }

    var help: String {
        switch self {
        case .normal: return "Draw the image as is; transparent PNG areas show the visualizer"
        case .screen: return "Lighten only: black backgrounds vanish, so a logo on black floats over the visuals"
        case .add: return "Add the image's light to the visuals, for glowing artwork"
        }
    }
}

/// A visible overlay with its decoded image, as the stage draws it.
struct StageImageOverlay: Identifiable {
    var overlay: ImageOverlay
    var image: CGImage

    var id: UUID { overlay.id }
}

/// The overlay images: their settings in the user defaults, copies of the
/// files in Application Support (so they survive the originals moving), and
/// the decoded images, downsampled for the stage.
final class ImageOverlayStore: ObservableObject {
    /// Longest side an image is decoded at; enough to fill a 4K output.
    static let maximumPixelSize = 3840

    private static let logger = Logger(subsystem: "com.auraviz.app", category: "ImageOverlays")

    /// Bottom to top.
    @Published var overlays: [ImageOverlay] = [] {
        didSet {
            guard let data = try? JSONEncoder().encode(overlays) else { return }
            UserDefaults.standard.set(data, forKey: SettingsKey.imageOverlays)
        }
    }
    /// Shows or hides all of them at once.
    @Published var isEnabled = false {
        didSet { UserDefaults.standard.set(isEnabled, forKey: SettingsKey.imageOverlaysEnabled) }
    }
    /// Decoded images by overlay; missing while loading or if unreadable.
    @Published private(set) var images: [UUID: CGImage] = [:]
    /// Overlays whose stored file is gone or can't be decoded.
    @Published private(set) var unreadable: Set<UUID> = []
    /// Why the last import skipped files, until the next import.
    @Published private(set) var importError: String?

    private let directory: URL?

    init() {
        do {
            let directory = try FileManager.default
                .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.auraviz.app", isDirectory: true)
                .appendingPathComponent("Overlays", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            self.directory = directory
        } catch {
            Self.logger.error("No Application Support directory, overlay images can't be added: \(error.localizedDescription)")
            directory = nil
        }
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: SettingsKey.imageOverlays),
           let overlays = try? JSONDecoder().decode([ImageOverlay].self, from: data) {
            self.overlays = overlays
        }
        isEnabled = defaults.bool(forKey: SettingsKey.imageOverlaysEnabled)
        loadStoredImages()
    }

    /// The visible overlays that have loaded, bottom to top. Listed while
    /// the overlay is off too, so the stage can fade them out and back in.
    var stageOverlays: [StageImageOverlay] {
        overlays.compactMap { overlay in
            guard overlay.isVisible, let image = images[overlay.id] else { return nil }
            return StageImageOverlay(overlay: overlay, image: image)
        }
    }

    /// Asks for images to add, without blocking the stage while the panel is up.
    func chooseImages() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Choose images to lay over the visualizers"
        panel.prompt = "Add"
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            self?.add(panel.urls)
        }
    }

    /// Copies the images in, decodes them off the main thread and turns the
    /// overlay on, so new images show at once. Files that aren't readable
    /// images are skipped and named in `importError`.
    func add(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        importError = nil
        guard let directory else {
            importError = "Couldn't create a folder for overlay images in Application Support."
            return
        }
        Task { @MainActor [weak self] in
            var skipped: [String] = []
            for url in urls {
                do {
                    let (fileName, image) = try await Task.detached(priority: .userInitiated) {
                        try Self.importImage(at: url, into: directory)
                    }.value
                    guard let self else { return }
                    let overlay = ImageOverlay(name: url.lastPathComponent, fileName: fileName)
                    self.images[overlay.id] = image
                    self.overlays.append(overlay)
                    self.isEnabled = true
                } catch {
                    Self.logger.error("Couldn't add \(url.lastPathComponent): \(error.localizedDescription)")
                    skipped.append(url.lastPathComponent)
                }
            }
            if !skipped.isEmpty {
                self?.importError = "Couldn't read \(skipped.joined(separator: ", ")) as an image."
            }
        }
    }

    /// Removes the overlay and its stored copy.
    func remove(_ overlay: ImageOverlay) {
        overlays.removeAll { $0.id == overlay.id }
        images[overlay.id] = nil
        unreadable.remove(overlay.id)
        if let directory {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(overlay.fileName))
        }
    }

    func toggleVisibility(of overlay: ImageOverlay) {
        guard let index = overlays.firstIndex(where: { $0.id == overlay.id }) else { return }
        overlays[index].isVisible.toggle()
    }

    func bringToFront(_ overlay: ImageOverlay) {
        guard let index = overlays.firstIndex(where: { $0.id == overlay.id }) else { return }
        overlays.append(overlays.remove(at: index))
    }

    func sendToBack(_ overlay: ImageOverlay) {
        guard let index = overlays.firstIndex(where: { $0.id == overlay.id }) else { return }
        overlays.insert(overlays.remove(at: index), at: 0)
    }

    /// A binding to one overlay by id, so its editor keeps editing the same
    /// image while others are added, reordered or removed.
    func binding(for overlay: ImageOverlay) -> Binding<ImageOverlay> {
        Binding(
            get: { self.overlays.first { $0.id == overlay.id } ?? overlay },
            set: { newValue in
                guard let index = self.overlays.firstIndex(where: { $0.id == overlay.id }) else { return }
                self.overlays[index] = newValue
            }
        )
    }

    private func loadStoredImages() {
        guard let directory else {
            unreadable = Set(overlays.map(\.id))
            return
        }
        let files = overlays.map { (id: $0.id, url: directory.appendingPathComponent($0.fileName)) }
        Task { @MainActor [weak self] in
            for file in files {
                let image = await Task.detached(priority: .userInitiated) {
                    Self.decodeImage(at: file.url)
                }.value
                guard let self else { return }
                if let image {
                    self.images[file.id] = image
                } else {
                    Self.logger.error("Couldn't load overlay image \(file.url.lastPathComponent)")
                    self.unreadable.insert(file.id)
                }
            }
        }
    }

    /// Copies `url` into `directory` under a fresh name and decodes it,
    /// removing the copy again if it isn't a readable image.
    private static func importImage(at url: URL, into directory: URL) throws -> (fileName: String, image: CGImage) {
        // Skips copying a dropped video or document; files of unknown type
        // still get a decode attempt.
        if let type = UTType(filenameExtension: url.pathExtension), !type.conforms(to: .image) {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "Not an image."])
        }
        let pathExtension = url.pathExtension.isEmpty ? "image" : url.pathExtension.lowercased()
        let fileName = "\(UUID().uuidString).\(pathExtension)"
        let destination = directory.appendingPathComponent(fileName)
        try FileManager.default.copyItem(at: url, to: destination)
        guard let image = decodeImage(at: destination) else {
            try? FileManager.default.removeItem(at: destination)
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "Not a readable image."])
        }
        return (fileName, image)
    }

    /// The image's first frame, upright and no larger than
    /// `maximumPixelSize` on its longest side.
    private static func decodeImage(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? maximumPixelSize
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? maximumPixelSize
        // Capped at the image's own size so small logos aren't upscaled.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, min(maximumPixelSize, max(width, height))),
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// One overlay image in the controls: its thumbnail, dimmed while hidden.
/// Click for its settings; right-click to show, hide, reorder or remove it.
struct ImageOverlayChip: View {
    @ObservedObject var store: ImageOverlayStore
    var overlay: ImageOverlay
    @State private var isEditing = false

    var body: some View {
        Button {
            isEditing.toggle()
        } label: {
            thumbnail
                .frame(width: 36, height: 24)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(.white.opacity(isEditing ? 0.75 : 0.18), lineWidth: 1)
                )
                .opacity(overlay.isVisible ? 1 : 0.35)
        }
        .buttonStyle(.plain)
        .help(store.unreadable.contains(overlay.id)
              ? "\(overlay.name) couldn't be loaded. Right-click to remove it."
              : "\(overlay.name): click for placement, size, opacity, blend and beat pulse")
        .popover(isPresented: $isEditing, arrowEdge: .top) {
            ImageOverlayEditor(overlay: store.binding(for: overlay)) {
                isEditing = false
                store.remove(overlay)
            }
        }
        .contextMenu {
            Button(overlay.isVisible ? "Hide" : "Show") { store.toggleVisibility(of: overlay) }
            Divider()
            Button("Bring to Front") { store.bringToFront(overlay) }
            Button("Send to Back") { store.sendToBack(overlay) }
            Divider()
            Button("Remove", role: .destructive) { store.remove(overlay) }
        }
        .accessibilityLabel("Overlay image \(overlay.name)")
        .accessibilityValue(overlay.isVisible ? "Shown" : "Hidden")
        .accessibilityHint("Opens its settings")
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let image = store.images[overlay.id] {
            Image(decorative: image, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                Color.white.opacity(0.08)
                Image(systemName: store.unreadable.contains(overlay.id) ? "exclamationmark.triangle.fill" : "hourglass")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(store.unreadable.contains(overlay.id) ? .orange : .white.opacity(0.6))
            }
        }
    }
}

/// Placement, size, opacity, blend and beat pulse for one overlay image.
private struct ImageOverlayEditor: View {
    @Binding var overlay: ImageOverlay
    var onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(overlay.name)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Toggle("Show", isOn: $overlay.isVisible)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .help("Show this image while Images is on")
            }
            Picker("Placement", selection: $overlay.placement) {
                ForEach(ImageOverlayPlacement.allCases) { placement in
                    Text(placement.rawValue).tag(placement)
                }
            }
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            slider("Size", value: $overlay.size, in: ImageOverlay.sizeRange, default: ImageOverlay.defaultSize, tint: .orange)
                .disabled(!overlay.placement.isSized)
                .help(overlay.placement.isSized ? "How much of the stage the image may fill" : "Fill Stage always covers the whole stage")
            slider("Opacity", value: $overlay.opacity, in: ImageOverlay.opacityRange, default: ImageOverlay.defaultOpacity, tint: .purple)
            VStack(alignment: .leading, spacing: 5) {
                Text("Blend").font(.system(size: 11, weight: .bold, design: .rounded)).foregroundStyle(.white.opacity(0.85))
                Picker("Blend", selection: $overlay.blend) {
                    ForEach(ImageOverlayBlend.allCases) { blend in
                        Text(blend.rawValue).tag(blend).help(blend.help)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .help(overlay.blend.help)
            }
            slider("Beat pulse", value: $overlay.pulse, in: ImageOverlay.pulseRange, default: ImageOverlay.defaultPulse, tint: .pink)
                .help("How far the image punches up on each beat; scaled by beat reactivity, 0 holds it still")
            Divider()
            Button("Remove Image", role: .destructive, action: onRemove)
                .controlSize(.small)
        }
        .padding(14)
        .frame(width: 260)
    }

    private func slider(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>, default defaultValue: Double, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title).font(.system(size: 11, weight: .bold, design: .rounded)).foregroundStyle(.white.opacity(0.85))
                Spacer()
                Text(String(format: "%.0f%%", value.wrappedValue * 100))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
            }
            ControlSlider(value: value, in: range, default: defaultValue) { String(format: "%.0f%%", $0 * 100) }
                .tint(tint)
                .accessibilityLabel(title)
        }
    }
}
