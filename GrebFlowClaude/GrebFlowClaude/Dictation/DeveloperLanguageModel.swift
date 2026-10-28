import Foundation
import os
import Speech

/// An on-device custom language model that teaches the recognizer where
/// developer terms fit. JSON and Jason sound the same, so a pronunciation
/// alone can't separate them. The phrase counts do that: "parse the JSON"
/// is common, and "ask Jason" keeps the name working.
///
/// Training happens once per `version` and the result lives in Application
/// Support. Bump `version` whenever the data below changes.
enum DeveloperLanguageModel {
    static let identifier = "com.grebban.GrebFlowClaude.developer"
    static let version = "1"

    /// File locations of a compiled model. Kept as URLs because
    /// `SFSpeechLanguageModel.Configuration` isn't Sendable.
    struct Files: Sendable, Equatable {
        let languageModel: URL
        let vocabulary: URL

        var configuration: SFSpeechLanguageModel.Configuration {
            SFSpeechLanguageModel.Configuration(languageModel: languageModel, vocabulary: vocabulary)
        }
    }

    static let formats = ["JSON", "YAML", "XML", "CSV"]

    static let formatVerbs = [
        "parse", "return", "send", "validate", "format", "log", "read", "write",
        "fetch", "serialize", "deserialize", "print", "check", "update", "load", "save",
    ]

    static let templates: [(body: String, count: Int)] = [
        ("<verb> the <format>", 200),
        ("<verb> the <format> response", 200),
        ("<verb> the <format> file", 150),
        ("<verb> the <format> payload", 100),
        ("<verb> it as <format>", 100),
        ("convert it to <format>", 100),
        ("the <format> schema", 100),
        ("a <format> object", 100),
        ("return <format> from the endpoint", 50),
        ("the response is <format>", 50),
    ]

    /// Fixed phrases. The Jason lines keep the name alive in ordinary speech.
    static let phrases: [(phrase: String, count: Int)] = [
        ("package dot JSON", 200),
        ("the JSON body", 150),
        ("JSON dot parse", 150),
        ("JSON dot stringify", 150),
        ("pretty print the JSON", 100),
        ("run npm install", 200),
        ("npm run build", 150),
        ("npm run dev", 150),
        ("npm test", 100),
        ("open GrebFlow", 150),
        ("in GrebFlow", 150),
        ("the GrebFlow dashboard", 100),
        ("GrebFlow settings", 100),
        ("ask Jason to review this", 50),
        ("tell Jason", 50),
        ("Jason said", 50),
        ("thanks Jason", 50),
    ]

    /// X-SAMPA from `SFCustomLanguageModelData.supportedPhonemes`. Quotes
    /// mark primary stress, percent marks secondary stress.
    static let pronunciations: [(grapheme: String, phonemes: [String])] = [
        ("JSON", ["dZ \"e s @ n", "dZ \"e s A n", "dZ %e s \"A n"]),
        ("GrebFlow", ["g r \"E b f l %o"]),
        ("npm", ["%E n p %i \"E m"]),
    ]

    static func makeData(locale: Locale) -> SFCustomLanguageModelData {
        let data = SFCustomLanguageModelData(locale: locale, identifier: identifier, version: version)
        let generator = SFCustomLanguageModelData.TemplatePhraseCountGenerator()
        generator.define(className: "format", values: formats)
        generator.define(className: "verb", values: formatVerbs)
        for template in templates {
            generator.insert(template: template.body, count: template.count)
        }
        data.insert(phraseCountGenerator: generator)
        for phrase in phrases {
            data.insert(phraseCount: .init(phrase: phrase.phrase, count: phrase.count))
        }
        for term in pronunciations {
            data.insert(term: .init(grapheme: term.grapheme, phonemes: term.phonemes))
        }
        return data
    }

    static func directory() throws -> URL {
        try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("com.grebban.GrebFlowClaude", isDirectory: true)
            .appendingPathComponent("LanguageModel", isDirectory: true)
            .appendingPathComponent("v\(version)", isDirectory: true)
    }

    /// Exports the training data and compiles it. The system caches the
    /// compiled model, so later launches return quickly.
    static func build(locale: Locale) async throws -> Files {
        let directory = try directory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let asset = directory.appendingPathComponent("training.bin")
        let files = Files(
            languageModel: directory.appendingPathComponent("model.lm"),
            vocabulary: directory.appendingPathComponent("vocabulary.voc")
        )
        if !FileManager.default.fileExists(atPath: asset.path) {
            try await makeData(locale: locale).export(to: asset)
        }
        try await SFSpeechLanguageModel.prepareCustomLanguageModel(
            for: asset,
            configuration: files.configuration,
            ignoresCache: false
        )
        return files
    }
}

/// Builds the custom model once per launch and hands the result to every
/// analyzer after that. A failure is logged and dictation carries on with
/// the stock model.
@MainActor
final class DeveloperLanguageModelStore {
    private let logger = Logger(subsystem: "com.grebban.GrebFlowClaude", category: "language-model")
    private var task: Task<DeveloperLanguageModel.Files?, Never>?

    func files(locale: Locale) async -> DeveloperLanguageModel.Files? {
        let task = self.task ?? Task { [logger] in
            let started = ContinuousClock.now
            do {
                let files = try await DeveloperLanguageModel.build(locale: locale)
                logger.info("Custom language model ready in \(started.duration(to: .now), privacy: .public)")
                return files
            } catch {
                logger.error("Custom language model failed: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
        self.task = task
        return await task.value
    }
}
