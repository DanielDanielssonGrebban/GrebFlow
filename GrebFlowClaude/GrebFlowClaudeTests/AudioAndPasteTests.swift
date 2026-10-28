@preconcurrency import AVFoundation
import CoreGraphics
import Foundation
import Speech
import Testing
@testable import GrebFlowClaude

@Suite("Audio tap")
struct AudioTapTests {
    private static func sineBuffer(format: AVAudioFormat, frames: AVAudioFrameCount) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let samples = buffer.floatChannelData![0]
        for index in 0..<Int(frames) {
            samples[index] = 0.4 * sin(Float(index) * 2 * .pi * 440 / Float(format.sampleRate))
        }
        return buffer
    }

    /// Builds the production tap on the main actor, then calls it from a
    /// background queue the way AVAudioEngine does. If the closure had picked
    /// up main-actor isolation this would trap. No microphone is involved.
    @MainActor
    @Test func productionTapRunsOffTheMainActor() async throws {
        let inputFormat = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let targetFormat = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false))
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()

        let tapRanOnMain = LockedBox<Bool?>(nil)
        let firstBufferOnMain = LockedBox<Bool?>(nil)
        let pipeline = AudioPipeline(
            targetFormat: targetFormat,
            continuation: continuation,
            onLevel: { _ in },
            onFirstBuffer: { _ in firstBufferOnMain.value = Thread.isMainThread }
        )
        let tap = AudioTapFactory.makeTap(for: pipeline)
        let buffer = Self.sineBuffer(format: inputFormat, frames: 4800)

        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue(label: "test.audio-callback").async {
                tap(buffer, AVAudioTime(hostTime: 0))
                tapRanOnMain.value = Thread.isMainThread
                done.resume()
            }
        }
        await pipeline.close()

        var received: [AnalyzerInput] = []
        for await input in stream { received.append(input) }

        #expect(tapRanOnMain.value == false)
        #expect(firstBufferOnMain.value == false)
        // One converted buffer plus the converter's flushed tail on close.
        #expect(!received.isEmpty)
        #expect(received.allSatisfy { $0.buffer.format == targetFormat })
        let totalFrames = received.reduce(0) { $0 + Int($1.buffer.frameLength) }
        #expect(abs(totalFrames - 1600) <= 16)
    }

    @MainActor
    @Test func buffersAfterCloseAreDropped() async throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let pipeline = AudioPipeline(targetFormat: format, continuation: continuation, onLevel: { _ in }, onFirstBuffer: { _ in })
        let tap = AudioTapFactory.makeTap(for: pipeline)
        await pipeline.close()
        tap(Self.sineBuffer(format: format, frames: 160), AVAudioTime(hostTime: 0))

        var count = 0
        for await _ in stream { count += 1 }
        #expect(count == 0)
    }

    @Test func deepCopyIsIndependentOfTheSource() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let original = Self.sineBuffer(format: format, frames: 64)
        let copy = try #require(original.deepCopy())
        original.floatChannelData![0][10] = 9
        #expect(copy.frameLength == 64)
        #expect(copy.floatChannelData![0][10] != 9)
    }
}

@Suite("Paste events")
struct PasteEventTests {
    private let modifierMasks: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
    // Return, Enter, keypad Enter, Option, Control, Shift.
    private let forbiddenKeys: Set<Int64> = [36, 76, 52, 58, 61, 59, 62, 56, 60]

    @Test func sequenceIsCommandVBalancedAndNeutral() throws {
        let factory = PasteEventFactory()
        for _ in 0..<5 {
            let source = try #require(factory.makeSource())
            #expect(source.localEventsSuppressionInterval == 0)
            for state in [CGEventSuppressionState.eventSuppressionStateSuppressionInterval, .eventSuppressionStateRemoteMouseDrag] {
                let filter = source.getLocalEventsFilterDuringSuppressionState(state)
                #expect(filter.contains(.permitLocalKeyboardEvents))
                #expect(filter.contains(.permitLocalMouseEvents))
                #expect(filter.contains(.permitSystemDefinedEvents))
            }

            let events = try #require(factory.makePasteEvents(source: source))
            #expect(events.map(\.type) == [.flagsChanged, .keyDown, .keyUp, .flagsChanged])
            #expect(events.map { $0.getIntegerValueField(.keyboardEventKeycode) } == [55, 9, 9, 55])
            #expect(events[0].flags.intersection(modifierMasks) == .maskCommand)
            #expect(events[1].flags.intersection(modifierMasks) == .maskCommand)
            #expect(events[2].flags.intersection(modifierMasks) == .maskCommand)
            #expect(events[3].flags.intersection(modifierMasks).isEmpty)

            for event in events {
                #expect(!forbiddenKeys.contains(event.getIntegerValueField(.keyboardEventKeycode)))
                #expect(!event.flags.contains(.maskAlternate))
                #expect(!event.flags.contains(.maskControl))
                #expect(!event.flags.contains(.maskShift))
            }

            let commandDowns = events.filter { $0.getIntegerValueField(.keyboardEventKeycode) == 55 && $0.flags.contains(.maskCommand) }
            let commandUps = events.filter { $0.getIntegerValueField(.keyboardEventKeycode) == 55 && !$0.flags.contains(.maskCommand) }
            #expect(commandDowns.count == 1)
            #expect(commandUps.count == 1)
        }
    }
}

@Suite("Paste normalization")
struct PasteNormalizerTests {
    @Test func collapsesLineBreaksTabsAndControlCharacters() {
        let input = "first line\nsecond\r\nthird\u{2028}fourth\u{2029}fifth\tsixth\u{0B}seventh\u{85}eighth\u{07}"
        #expect(PasteNormalizer.normalize(input) == "first line second third fourth fifth sixth seventh eighth")
    }

    @Test func keepsPunctuationShellCharactersAndUnicode() {
        let input = "run `git log | grep fix && echo $HOME > out.txt`; then café, naïve, 日本語 — ok?"
        #expect(PasteNormalizer.normalize(input) == input)
    }

    @Test func trimsAndCollapsesWhitespace() {
        #expect(PasteNormalizer.normalize("\n\n  open   the SwiftUI view \n") == "open the SwiftUI view")
        #expect(PasteNormalizer.normalize("\n\t \r") == "")
    }

    @Test func insertionEndsWithExactlyOneSpace() {
        #expect(PasteNormalizer.insertionText(for: "write tests") == "write tests ")
        #expect(PasteNormalizer.insertionText(for: "write tests  \n") == "write tests ")
        #expect(PasteNormalizer.insertionText(for: "  ") == nil)
        #expect(PasteNormalizer.insertionText(for: "") == nil)
    }

    @Test func neverContainsReturnAfterNormalizing() {
        let tricky = "rm -rf build\nnpm publish\r\n"
        let normalized = PasteNormalizer.normalize(tricky)
        #expect(!normalized.contains("\n"))
        #expect(!normalized.contains("\r"))
    }
}

@Suite("Shortcut interpreter")
struct ShortcutInterpreterTests {
    // Generic + device flags as reported by flagsChanged events.
    let rightOptionDown: UInt64 = 0x0008_0000 | 0x40
    let leftOptionDown: UInt64 = 0x0008_0000 | 0x20
    let bothOptionsDown: UInt64 = 0x0008_0000 | 0x40 | 0x20

    @Test func rightOptionPressAndRelease() {
        var interpreter = ShortcutInterpreter(shortcut: .rightOption)
        #expect(interpreter.interpret(type: .flagsChanged, keyCode: 61, flags: rightOptionDown, sourcePID: 0, sourceStateID: 1) == .pressed)
        #expect(interpreter.interpret(type: .flagsChanged, keyCode: 61, flags: 0, sourcePID: 0, sourceStateID: 1) == .released)
    }

    @Test func leftOptionIsIgnored() {
        var interpreter = ShortcutInterpreter(shortcut: .rightOption)
        #expect(interpreter.interpret(type: .flagsChanged, keyCode: 58, flags: leftOptionDown, sourcePID: 0, sourceStateID: 1) == .ignore)
        #expect(interpreter.interpret(type: .flagsChanged, keyCode: 58, flags: 0, sourcePID: 0, sourceStateID: 1) == .ignore)
        #expect(!interpreter.isHeld)
    }

    @Test func bothOptionKeysHeldTrackRightIndependently() {
        var interpreter = ShortcutInterpreter(shortcut: .rightOption)
        #expect(interpreter.interpret(type: .flagsChanged, keyCode: 58, flags: leftOptionDown, sourcePID: 0, sourceStateID: 1) == .ignore)
        #expect(interpreter.interpret(type: .flagsChanged, keyCode: 61, flags: bothOptionsDown, sourcePID: 0, sourceStateID: 1) == .pressed)
        // Releasing right while left stays down still releases the shortcut.
        #expect(interpreter.interpret(type: .flagsChanged, keyCode: 61, flags: leftOptionDown, sourcePID: 0, sourceStateID: 1) == .released)
        #expect(interpreter.interpret(type: .flagsChanged, keyCode: 58, flags: 0, sourcePID: 0, sourceStateID: 1) == .ignore)
    }

    @Test func escapeAndOtherKeys() {
        var interpreter = ShortcutInterpreter(shortcut: .rightOption)
        #expect(interpreter.interpret(type: .keyDown, keyCode: 0, flags: 0, sourcePID: 0, sourceStateID: 1) == .ignore)
        _ = interpreter.interpret(type: .flagsChanged, keyCode: 61, flags: rightOptionDown, sourcePID: 0, sourceStateID: 1)
        #expect(interpreter.interpret(type: .keyDown, keyCode: 53, flags: rightOptionDown, sourcePID: 0, sourceStateID: 1) == .escape)
        #expect(interpreter.interpret(type: .keyDown, keyCode: 19, flags: rightOptionDown, sourcePID: 0, sourceStateID: 1) == .otherKeyWhileHeld)
    }

    @Test func syntheticEventsAreIgnored() {
        var interpreter = ShortcutInterpreter(shortcut: .rightOption)
        // Posted by another process.
        #expect(interpreter.interpret(type: .flagsChanged, keyCode: 61, flags: rightOptionDown, sourcePID: 4242, sourceStateID: 1) == .ignore)
        // Posted from a private source state, like every variant's Command-V.
        #expect(interpreter.interpret(type: .flagsChanged, keyCode: 61, flags: rightOptionDown, sourcePID: 0, sourceStateID: -1) == .ignore)
        #expect(!interpreter.isHeld)
    }

    @Test func otherVariantsKeysAndPasteSequencesLeaveItIdle() {
        var interpreter = ShortcutInterpreter(shortcut: .rightOption)
        // GrebFlowSol (right Command) and GrebFlowArgon (right Shift).
        #expect(interpreter.interpret(type: .flagsChanged, keyCode: 54, flags: 0x0010_0000 | 0x10, sourcePID: 0, sourceStateID: 1) == .ignore)
        #expect(interpreter.interpret(type: .flagsChanged, keyCode: 54, flags: 0, sourcePID: 0, sourceStateID: 1) == .ignore)
        #expect(interpreter.interpret(type: .flagsChanged, keyCode: 60, flags: 0x0002_0000 | 0x04, sourcePID: 0, sourceStateID: 1) == .ignore)
        #expect(interpreter.interpret(type: .flagsChanged, keyCode: 60, flags: 0, sourcePID: 0, sourceStateID: 1) == .ignore)
        // Their Command-V comes from another process.
        #expect(interpreter.interpret(type: .flagsChanged, keyCode: 55, flags: 0x0010_0000, sourcePID: 999, sourceStateID: -1) == .ignore)
        #expect(interpreter.interpret(type: .keyDown, keyCode: 9, flags: 0x0010_0000, sourcePID: 999, sourceStateID: -1) == .ignore)
        #expect(!interpreter.isHeld)
    }

    @Test func anotherModifierDuringTheHoldCancels() {
        var interpreter = ShortcutInterpreter(shortcut: .rightOption)
        _ = interpreter.interpret(type: .flagsChanged, keyCode: 61, flags: rightOptionDown, sourcePID: 0, sourceStateID: 1)
        // Right Command goes down too, for example for GrebFlowSol.
        let both = rightOptionDown | 0x0010_0000 | 0x10
        #expect(interpreter.interpret(type: .flagsChanged, keyCode: 54, flags: both, sourcePID: 0, sourceStateID: 1) == .otherKeyWhileHeld)
        // Letting it go again isn't a new press.
        #expect(interpreter.interpret(type: .flagsChanged, keyCode: 54, flags: rightOptionDown, sourcePID: 0, sourceStateID: 1) == .ignore)
    }

    @Test func otherShortcutsUseTheirOwnKey() {
        var interpreter = ShortcutInterpreter(shortcut: .rightControl)
        #expect(interpreter.interpret(type: .flagsChanged, keyCode: 61, flags: rightOptionDown, sourcePID: 0, sourceStateID: 1) == .ignore)
        #expect(interpreter.interpret(type: .flagsChanged, keyCode: 62, flags: 0x0004_0000 | 0x2000, sourcePID: 0, sourceStateID: 1) == .pressed)
        #expect(interpreter.interpret(type: .flagsChanged, keyCode: 62, flags: 0, sourcePID: 0, sourceStateID: 1) == .released)
    }

    @Test func fallsBackToGenericFlagWithoutDeviceBits() {
        var interpreter = ShortcutInterpreter(shortcut: .rightOption)
        #expect(interpreter.interpret(type: .flagsChanged, keyCode: 61, flags: 0x0008_0000, sourcePID: 0, sourceStateID: 1) == .pressed)
        #expect(interpreter.interpret(type: .flagsChanged, keyCode: 61, flags: 0, sourcePID: 0, sourceStateID: 1) == .released)
    }
}

@Suite("Transcript assembly")
struct TranscriptAssemblerTests {
    @Test func volatileResultsReplaceEachOther() {
        var assembler = TranscriptAssembler()
        assembler.apply(TranscriptSegment(start: 0, end: 1, text: "write", isFinal: false))
        assembler.apply(TranscriptSegment(start: 0, end: 1.5, text: "write tests", isFinal: false))
        assembler.apply(TranscriptSegment(start: 0, end: 2, text: "write tests for", isFinal: false))
        #expect(assembler.displayText == "write tests for")
        #expect(assembler.finalText == "")
    }

    @Test func finalSegmentsCommitOncePerRange() {
        var assembler = TranscriptAssembler()
        assembler.apply(TranscriptSegment(start: 0, end: 2, text: "Write tests", isFinal: true))
        assembler.apply(TranscriptSegment(start: 0, end: 2, text: "Write tests", isFinal: true))
        assembler.apply(TranscriptSegment(start: 2, end: 3, text: "for the", isFinal: false))
        assembler.apply(TranscriptSegment(start: 2, end: 4, text: "for the cart.", isFinal: true))
        #expect(assembler.finalText == "Write tests for the cart.")
        #expect(!assembler.hasVolatileText)
    }

    @Test func revisedFinalReplacesEarlierOneInsideItsRange() {
        var assembler = TranscriptAssembler()
        assembler.apply(TranscriptSegment(start: 0, end: 1, text: "Right", isFinal: true))
        assembler.apply(TranscriptSegment(start: 0, end: 2, text: "Write tests", isFinal: true))
        #expect(assembler.finalText == "Write tests")
    }

    @Test func segmentsAreOrderedByAudioTime() {
        var assembler = TranscriptAssembler()
        assembler.apply(TranscriptSegment(start: 2, end: 3, text: "second", isFinal: true))
        assembler.apply(TranscriptSegment(start: 0, end: 1, text: "first", isFinal: true))
        #expect(assembler.finalText == "first second")
    }
}

@MainActor
@Suite("Paste guard")
struct PasteGuardTests {
    let environment = FakePasteEnvironment()
    let destination = PasteDestination(processID: 42, bundleID: "com.example.Terminal", focusedElement: nil)

    @Test func pastesWhenEverythingIsClear() async {
        let inserter = PasteInserter(environment: environment, releaseTimeout: .milliseconds(100))
        let result = await inserter.insert("hello ", into: destination, shortcut: .rightOption)
        #expect(result == .pasteAttempted)
        #expect(environment.clipboard == "hello ")
        #expect(environment.postedEvents.count == 4)
    }

    @Test func waitsForEveryModifierToBeReleased() async {
        // Shift (another variant's key) is held for a moment, then released.
        environment.flagSequence = [.maskShift, .maskShift, .maskSecondaryFn, []]
        let inserter = PasteInserter(environment: environment, releaseTimeout: .seconds(1))
        let result = await inserter.insert("hello ", into: destination, shortcut: .rightOption)
        #expect(result == .pasteAttempted)
        #expect(environment.flagReads >= 4)
    }

    @Test func fallsBackToCopyOnlyAfterTimeout() async {
        environment.flagSequence = [.maskCommand]
        let inserter = PasteInserter(environment: environment, releaseTimeout: .milliseconds(50))
        let result = await inserter.insert("hello ", into: destination, shortcut: .rightOption)
        #expect(result == .copyOnly(.modifiersStillHeld))
        #expect(environment.postedEvents.isEmpty)
        #expect(environment.clipboard == nil)
    }

    @Test func skipsWhenTheClipboardChangesBeforePosting() async {
        environment.anotherAppWritesAfterUs = true
        let inserter = PasteInserter(environment: environment, releaseTimeout: .milliseconds(100))
        let result = await inserter.insert("hello ", into: destination, shortcut: .rightOption)
        #expect(result == .copyOnly(.clipboardChanged))
        #expect(environment.postedEvents.isEmpty)
    }

    @Test func skipsWhenTheActiveAppChanged() async {
        environment.frontmostPID = 7
        let inserter = PasteInserter(environment: environment, releaseTimeout: .milliseconds(100))
        let result = await inserter.insert("hello ", into: destination, shortcut: .rightOption)
        #expect(result == .copyOnly(.destinationChanged))
        #expect(environment.postedEvents.isEmpty)
    }

    @Test func skipsInSecureInput() async {
        environment.isSecureInputActive = true
        let inserter = PasteInserter(environment: environment, releaseTimeout: .milliseconds(100))
        #expect(await inserter.insert("hello ", into: destination, shortcut: .rightOption) == .copyOnly(.secureInput))
    }
}
