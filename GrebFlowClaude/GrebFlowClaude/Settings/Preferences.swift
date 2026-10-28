import Foundation
import Observation

enum Dataset: String, CaseIterable, Identifiable, Sendable {
    case real
    case sample

    var id: String { rawValue }

    var label: String {
        switch self {
        case .real: "Real history"
        case .sample: "Sample data"
        }
    }
}

/// Hold keys the dictation shortcut can use. Each one is a single physical
/// modifier on the right side of the keyboard, told apart from its left
/// counterpart by the device-dependent bits in the event flags.
enum DictationShortcut: String, CaseIterable, Identifiable, Sendable {
    case rightOption
    case rightCommand
    case rightControl
    case rightShift

    var id: String { rawValue }

    var label: String {
        switch self {
        case .rightOption: "Right Option"
        case .rightCommand: "Right Command"
        case .rightControl: "Right Control"
        case .rightShift: "Right Shift"
        }
    }

    var keyCode: Int64 {
        switch self {
        case .rightOption: 61
        case .rightCommand: 54
        case .rightControl: 62
        case .rightShift: 60
        }
    }

    /// NX_DEVICERALTKEYMASK, NX_DEVICERCMDKEYMASK, NX_DEVICERCTLKEYMASK,
    /// NX_DEVICERSHIFTKEYMASK.
    var deviceFlag: UInt64 {
        switch self {
        case .rightOption: 0x0000_0040
        case .rightCommand: 0x0000_0010
        case .rightControl: 0x0000_2000
        case .rightShift: 0x0000_0004
        }
    }

    /// Device bit of the matching left-side key.
    var leftDeviceFlag: UInt64 {
        switch self {
        case .rightOption: 0x0000_0020
        case .rightCommand: 0x0000_0008
        case .rightControl: 0x0000_0001
        case .rightShift: 0x0000_0002
        }
    }

    /// Generic modifier flag (maskAlternate, maskCommand, maskControl, maskShift).
    var genericFlag: UInt64 {
        switch self {
        case .rightOption: 0x0008_0000
        case .rightCommand: 0x0010_0000
        case .rightControl: 0x0004_0000
        case .rightShift: 0x0002_0000
        }
    }

    /// The parallel build that uses this key by default, if any.
    var otherVariant: String? {
        switch self {
        case .rightCommand: "GrebFlowSol"
        case .rightShift: "GrebFlowArgon"
        case .rightOption, .rightControl: nil
        }
    }
}

@MainActor
@Observable
final class Preferences {
    /// Claude Haiku 5.5, the current low-cost Haiku model in Anthropic's
    /// catalog. Editable in Settings; never changed automatically.
    static let defaultModelID = "claude-haiku-5-5"

    private let defaults: UserDefaults

    var modelID: String {
        didSet { defaults.set(modelID, forKey: Keys.modelID) }
    }

    var shortcut: DictationShortcut {
        didSet { defaults.set(shortcut.rawValue, forKey: Keys.shortcut) }
    }

    var dataset: Dataset {
        didSet { defaults.set(dataset.rawValue, forKey: Keys.dataset) }
    }

    /// Consent to send transcripts for AI grouping, given separately for
    /// each dataset. Off until the user turns it on.
    private(set) var realAnalysisEnabled: Bool {
        didSet { defaults.set(realAnalysisEnabled, forKey: Keys.realAnalysis) }
    }

    private(set) var sampleAnalysisEnabled: Bool {
        didSet { defaults.set(sampleAnalysisEnabled, forKey: Keys.sampleAnalysis) }
    }

    /// `DemoSeeder.version` the sample store was last built with.
    var sampleSeedVersion: Int {
        didSet { defaults.set(sampleSeedVersion, forKey: Keys.sampleSeedVersion) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        modelID = defaults.string(forKey: Keys.modelID) ?? Self.defaultModelID
        shortcut = defaults.string(forKey: Keys.shortcut).flatMap(DictationShortcut.init(rawValue:)) ?? .rightOption
        dataset = defaults.string(forKey: Keys.dataset).flatMap(Dataset.init(rawValue:)) ?? .real
        realAnalysisEnabled = defaults.bool(forKey: Keys.realAnalysis)
        sampleAnalysisEnabled = defaults.bool(forKey: Keys.sampleAnalysis)
        sampleSeedVersion = defaults.integer(forKey: Keys.sampleSeedVersion)
    }

    func isAnalysisEnabled(for dataset: Dataset) -> Bool {
        dataset == .real ? realAnalysisEnabled : sampleAnalysisEnabled
    }

    func setAnalysisEnabled(_ enabled: Bool, for dataset: Dataset) {
        switch dataset {
        case .real: realAnalysisEnabled = enabled
        case .sample: sampleAnalysisEnabled = enabled
        }
    }

    var isLowCostModel: Bool { modelID.hasPrefix("claude-haiku") }

    private enum Keys {
        static let modelID = "anthropicModelID"
        static let shortcut = "dictationShortcut"
        static let dataset = "dashboardDataset"
        static let realAnalysis = "analysisEnabled.real"
        static let sampleAnalysis = "analysisEnabled.sample"
        static let sampleSeedVersion = "sampleSeedVersion"
    }
}
