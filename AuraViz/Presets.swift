import Foundation
import os
import SwiftUI

/// UserDefaults keys for the settings restored at launch.
enum SettingsKey {
    static let mode = "visualMode"
    static let theme = "colorTheme"
    static let circleFramesPerSecond = "circleFramesPerSecond"
    static let inputMode = "inputMode"
    static let sensitivity = "sensitivity"
    static let autoGainEnabled = "autoGainEnabled"
    static let smoothing = "smoothing"
    static let beatReactivity = "beatReactivity"
}

extension UserDefaults {
    /// The stored value clamped to `range`, or nil if none is stored.
    func double(forKey key: String, in range: ClosedRange<Double>) -> Double? {
        guard object(forKey: key) != nil else { return nil }
        return double(forKey: key).clamped(to: range)
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

/// A named snapshot of every visual setting. The input source isn't part of
/// it: recalling a look shouldn't switch what's being listened to.
struct Preset: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var mode: VisualMode = .circle
    var theme: ColorTheme = .aurora
    var circleFramesPerSecond = 30
    var sensitivity = 1.0
    var autoGainEnabled = true
    var smoothing = 0.75
    var beatReactivity = 0.6
}

extension Preset {
    init(name: String, audio: AudioEngineManager, performance: PerformanceState) {
        self.init(
            name: name,
            mode: performance.mode,
            theme: performance.theme,
            circleFramesPerSecond: performance.circleFramesPerSecond,
            sensitivity: audio.sensitivity,
            autoGainEnabled: audio.autoGainEnabled,
            smoothing: audio.smoothing,
            beatReactivity: audio.beatReactivity
        )
    }

    /// Missing or unknown values fall back to the defaults, so presets saved
    /// before a setting existed (or with a since-renamed theme) still load.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = Preset(name: "")
        id = (try? container.decode(UUID.self, forKey: .id)) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        mode = (try? container.decode(VisualMode.self, forKey: .mode)) ?? fallback.mode
        theme = (try? container.decode(ColorTheme.self, forKey: .theme)) ?? fallback.theme
        circleFramesPerSecond = (try? container.decode(Int.self, forKey: .circleFramesPerSecond)) ?? fallback.circleFramesPerSecond
        sensitivity = (try? container.decode(Double.self, forKey: .sensitivity)) ?? fallback.sensitivity
        autoGainEnabled = (try? container.decode(Bool.self, forKey: .autoGainEnabled)) ?? fallback.autoGainEnabled
        smoothing = (try? container.decode(Double.self, forKey: .smoothing)) ?? fallback.smoothing
        beatReactivity = (try? container.decode(Double.self, forKey: .beatReactivity)) ?? fallback.beatReactivity
    }

    /// Crossfades the stage to this preset's look and sets its controls.
    func apply(to audio: AudioEngineManager, performance: PerformanceState) {
        performance.crossfade {
            performance.mode = mode
            performance.theme = theme
            if PerformanceState.circleFrameRates.contains(circleFramesPerSecond) {
                performance.circleFramesPerSecond = circleFramesPerSecond
            }
        }
        audio.sensitivity = sensitivity.clamped(to: AudioEngineManager.sensitivityRange)
        audio.autoGainEnabled = autoGainEnabled
        audio.smoothing = smoothing.clamped(to: AudioEngineManager.smoothingRange)
        audio.beatReactivity = beatReactivity.clamped(to: AudioEngineManager.beatReactivityRange)
    }
}

/// The built-in presets plus the user's own, which are saved as JSON in
/// Application Support.
final class PresetStore: ObservableObject {
    static let builtIn: [Preset] = [
        Preset(
            id: UUID(uuidString: "6A1F3C52-0B7E-4C1D-9A55-1C0FFEE00001")!,
            name: "Chill",
            mode: .waves,
            theme: .ocean,
            sensitivity: 1.0,
            smoothing: 0.9,
            beatReactivity: 0.3
        ),
        Preset(
            id: UUID(uuidString: "6A1F3C52-0B7E-4C1D-9A55-1C0FFEE00002")!,
            name: "Peak Time",
            mode: .circle,
            theme: .cyberpunk,
            circleFramesPerSecond: 60,
            sensitivity: 1.2,
            smoothing: 0.25,
            beatReactivity: 1.0
        ),
        Preset(
            id: UUID(uuidString: "6A1F3C52-0B7E-4C1D-9A55-1C0FFEE00003")!,
            name: "Retro",
            mode: .y2k,
            theme: .y2k,
            smoothing: 0.6,
            beatReactivity: 0.7
        ),
        Preset(
            id: UUID(uuidString: "6A1F3C52-0B7E-4C1D-9A55-1C0FFEE00004")!,
            name: "Hyperdrive",
            mode: .tunnel,
            theme: .tokyoNight,
            circleFramesPerSecond: 60,
            sensitivity: 1.1,
            smoothing: 0.4,
            beatReactivity: 0.9
        ),
        Preset(
            id: UUID(uuidString: "6A1F3C52-0B7E-4C1D-9A55-1C0FFEE00005")!,
            name: "Fireworks",
            mode: .particles,
            theme: .sunset,
            circleFramesPerSecond: 60,
            sensitivity: 1.0,
            smoothing: 0.5,
            beatReactivity: 1.0
        ),
    ]

    private static let logger = Logger(subsystem: "com.auraviz.app", category: "Presets")

    @Published private(set) var userPresets: [Preset] = []

    private let fileURL: URL?

    init() {
        do {
            let directory = try FileManager.default
                .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.auraviz.app", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            fileURL = directory.appendingPathComponent("Presets.json")
        } catch {
            Self.logger.error("No Application Support directory, presets won't be saved: \(error.localizedDescription)")
            fileURL = nil
        }
        load()
    }

    /// Saves the current settings as a user preset. Saving under the name of
    /// an existing user preset replaces it.
    func save(name: String, audio: AudioEngineManager, performance: PerformanceState) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        var preset = Preset(name: name, audio: audio, performance: performance)
        if let index = userPresets.firstIndex(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
            preset.id = userPresets[index].id
            userPresets[index] = preset
        } else {
            userPresets.append(preset)
        }
        persist()
    }

    func delete(_ preset: Preset) {
        userPresets.removeAll { $0.id == preset.id }
        persist()
    }

    private func load() {
        guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            userPresets = try JSONDecoder().decode([Preset].self, from: Data(contentsOf: fileURL))
        } catch {
            // Keep the unreadable file rather than overwrite it on the next save.
            let backupURL = fileURL.deletingPathExtension().appendingPathExtension("unreadable.json")
            try? FileManager.default.removeItem(at: backupURL)
            try? FileManager.default.moveItem(at: fileURL, to: backupURL)
            Self.logger.error("Couldn't read presets, moved to \(backupURL.lastPathComponent): \(error.localizedDescription)")
        }
    }

    private func persist() {
        guard let fileURL else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(userPresets).write(to: fileURL, options: .atomic)
        } catch {
            Self.logger.error("Couldn't save presets: \(error.localizedDescription)")
        }
    }
}

/// Save, recall and delete, shared by the header's Presets menu and the
/// menu bar's.
struct PresetsMenuContent: View {
    let audio: AudioEngineManager
    let performance: PerformanceState
    @ObservedObject var presets: PresetStore

    var body: some View {
        Button("Save Current…") { performance.isNamingPreset = true }
        Divider()
        Section("Built-in") {
            ForEach(PresetStore.builtIn) { preset in
                Button(preset.name) { preset.apply(to: audio, performance: performance) }
            }
        }
        if !presets.userPresets.isEmpty {
            Section("My Presets") {
                ForEach(presets.userPresets) { preset in
                    Button(preset.name) { preset.apply(to: audio, performance: performance) }
                }
            }
            Divider()
            Menu("Delete") {
                ForEach(presets.userPresets) { preset in
                    Button(preset.name, role: .destructive) { presets.delete(preset) }
                }
            }
        }
    }
}
