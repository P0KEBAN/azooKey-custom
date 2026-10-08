import Core
import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary
import Testing

private func englishEvent(_ text: String?, flags: KeyEventCore.ModifierFlag = [], code: UInt16 = 0) -> KeyEventCore {
    KeyEventCore(modifierFlags: flags, characters: text, charactersIgnoringModifiers: text?.lowercased(), keyCode: code)
}

// Coreだけでキー解釈・既存の状態遷移・変換エンジンをつなぐ。
// ConverterServerの配線とクライアントへの副作用は実機確認に残す。
@MainActor
private final class EnglishInputSequence {
    let manager = SegmentsManager(
        kanaKanjiConverter: .withDefaultDictionary(),
        applicationDirectoryURL: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString),
        containerURL: nil,
        context: .init(useZenzai: false)
    )
    var state: InputState = .none
    var language: InputLanguage = .japanese
    var marked = false
    var committed = ""
    var text: String {
        manager.getCurrentMarkedText(inputState: state).reduce(into: "") { $0 += $1.content }
    }

    // 入力処理を再現するテスト用補助関数。
    @discardableResult
    // swiftlint:disable:next cyclomatic_complexity
    func key(_ event: KeyEventCore, debug: Bool = false) -> ClientAction {
        marked = TemporaryEnglishInput.isActive(marked, inputState: state)
        let starting = TemporaryEnglishInput.shouldStart(event: event, inputLanguage: language, inputState: state)
        let interpretation = TemporaryEnglishInput.interpretationLanguage(starting: starting, active: marked, inputLanguage: language)
        let userAction = UserAction.getUserAction(eventCore: event, inputLanguage: interpretation, typeBackSlash: false)
        let (originalAction, originalCallback) = state.event(
            eventCore: event, userAction: userAction, inputLanguage: interpretation,
            liveConversionEnabled: Config.LiveConversion().value, enableDebugWindow: debug, enableSuggestion: false
        )
        let (action, callback) = TemporaryEnglishInput.resolveAction(
            originalAction, callback: originalCallback, starting: starting, active: marked, inputState: state
        )
        marked = starting || marked
        let style: InputStyle = interpretation == .english ? .direct : .roman2kana
        switch action {
        case .appendToMarkedText(let text):
            manager.insertAtCursorPosition(text, inputStyle: style)
        case .appendPieceToMarkedText(let pieces):
            manager.insertAtCursorPosition(pieces: pieces, inputStyle: style)
        case .commitMarkedTextAndAppendPieceToMarkedText(let pieces):
            committed += manager.commitMarkedText(inputState: state)
            manager.insertAtCursorPosition(pieces: pieces, inputStyle: style)
        case .insertWithoutMarkedText(let text):
            committed += text
        case .commitMarkedText:
            committed += manager.commitMarkedText(inputState: state)
        case .removeLastMarkedText:
            manager.deleteBackwardFromCursorPosition()
            manager.requestResettingSelection()
        case .stopComposition:
            manager.stopComposition()
        case .selectInputLanguage(let next):
            language = next
        case .enterCandidateSelectionMode:
            manager.insertCompositionSeparator(inputStyle: style, skipUpdate: true)
            manager.update(requestRichCandidates: true)
        case .submitHiraganaCandidate:
            committed += manager.getModifiedRubyCandidate(inputState: state) { $0.toHiragana() }.text
            manager.stopComposition()
        case .acceptPredictionCandidate:
            manager.acceptPredictionCandidate()
        case .consume, .fallthrough, .enableDebugWindow, .disableDebugWindow:
            break
        default:
            Issue.record("Unsupported sequence action: \(action)")
        }
        switch callback {
        case .fallthrough:
            break
        case .transition(let next):
            state = next
        case .basedOnBackspace(let empty, let nonempty), .basedOnSubmitCandidate(let empty, let nonempty):
            state = manager.isEmpty ? empty : nonempty
        }
        marked = TemporaryEnglishInput.markAfterAction(marked, action: action, inputState: state)
        return action
    }

    func type(_ text: String) {
        for character in text {
            let string = String(character)
            key(englishEvent(string, flags: character.isUppercase ? [.shift] : [], code: string == " " ? 49 : (string == "1" ? 18 : 0)))
        }
    }
}

@Suite("Temporary English input")
struct TemporaryEnglishInputTests {
    @Test func startConditions() {
        for state: InputState in [.none, .composing, .previewing, .selecting] {
            for letter in "ABCDEFGHIJKLMNOPQRSTUVWXYZ" {
                #expect(TemporaryEnglishInput.shouldStart(event: englishEvent(String(letter), flags: [.shift]), inputLanguage: .japanese, inputState: state))
            }
        }
        for text in [nil, "", "a", "!", "1", "Ａ", "Ä", "AB"] {
            #expect(!TemporaryEnglishInput.shouldStart(event: englishEvent(text, flags: [.shift]), inputLanguage: .japanese, inputState: .none))
        }
        for flags: KeyEventCore.ModifierFlag in [[], [.shift, .command], [.shift, .control], [.shift, .option]] {
            #expect(!TemporaryEnglishInput.shouldStart(event: englishEvent("A", flags: flags), inputLanguage: .japanese, inputState: .none))
        }
        for state: InputState in [.unicodeInput(""), .replaceSuggestion, .attachDiacritic("´")] {
            #expect(!TemporaryEnglishInput.shouldStart(event: englishEvent("A", flags: [.shift]), inputLanguage: .japanese, inputState: state))
        }
        #expect(!TemporaryEnglishInput.shouldStart(event: englishEvent("A", flags: [.shift]), inputLanguage: .english, inputState: .none))
    }

    @MainActor @Test func startingKeyFromEverySupportedState() {
        for state: InputState in [.none, .composing, .previewing, .selecting] {
            let input = EnglishInputSequence()
            input.state = state
            if state != .none {
                input.manager.insertAtCursorPosition("あ", inputStyle: .direct)
            }
            input.type("A")
            #expect(input.state == .composing)
            #expect(input.marked)
            #expect(input.language == .japanese)
            #expect(input.text == (state == .composing ? "あA" : "A"))
            #expect(input.committed == (state == .previewing || state == .selecting ? "あ" : ""))
        }
    }

    @MainActor @Test(arguments: ["Apple", "Discord", "YouTube", "ChatGPT", "APPLE", "GitHub", "App a", "Mac mini", "Apple1-"])
    func enginePreservesEnglish(word: String) {
        let input = EnglishInputSequence()
        input.type(word)
        #expect(input.text == word)
        #expect(input.marked)
        #expect(input.state == .composing)
        #expect(input.language == .japanese)
        input.key(englishEvent("\r", code: 36))
        #expect(input.committed == word)
        #expect(input.text.isEmpty)
        #expect(!input.marked)
        #expect(input.state == .none)
        input.type("a")
        #expect(input.text == "あ")
        #expect(!input.marked)
    }

    @MainActor @Test(arguments: ["Apple", "Discord", "YouTube", "ChatGPT", "APPLE", "iPhone", "GitHub", "App a", "Mac mini", "Apple1-"])
    func directEngineBaseline(word: String) {
        let input = EnglishInputSequence()
        input.manager.insertAtCursorPosition(word, inputStyle: .direct)
        input.state = .composing
        #expect(input.text == word)
        #expect(input.manager.commitMarkedText(inputState: .composing) == word)
        #expect(input.manager.isEmpty)
    }

    @MainActor @Test func tabDoesNotChangeComposition() {
        let input = EnglishInputSequence()
        input.type("App")
        let before = input.text
        let action = input.key(englishEvent("\t", code: 48))
        guard case .consume = action else {
            Issue.record("Tab must be consumed")
            return
        }
        #expect(input.text == before)
        #expect(input.committed.isEmpty)
        #expect(input.marked)
        #expect(input.state == .composing)
    }

    @MainActor @Test func escapeCancelsAndBackspaceEndsOnlyWhenEmpty() {
        let input = EnglishInputSequence()
        input.type("App")
        input.key(englishEvent("\u{7f}", code: 51))
        #expect(input.text == "Ap")
        #expect(input.marked)
        input.type("p")
        #expect(input.text == "App")
        input.key(englishEvent("\u{1b}", code: 53))
        #expect(input.text.isEmpty)
        #expect(input.committed.isEmpty)
        #expect(!input.marked)
        #expect(input.state == .none)
        input.type("A")
        input.key(englishEvent("\u{7f}", code: 51))
        #expect(input.state == .none)
        #expect(!input.marked)
        input.type("a")
        #expect(input.text == "あ")
    }

    @MainActor @Test func kanaContinuesSameCompositionAndEnglishSwitchUsesExistingMode() {
        let input = EnglishInputSequence()
        input.type("App")
        input.key(englishEvent(nil, code: 104))
        #expect(!input.marked)
        #expect(input.state == .composing)
        #expect(input.text == "App")
        input.type("a")
        #expect(input.text == "Appあ")
        input.type("A")
        #expect(input.marked)
        input.key(englishEvent(nil, code: 102))
        #expect(!input.marked)
        #expect(input.language == .english)
        input.type("a")
        #expect(input.text == "AppあAa")
        input.key(englishEvent("\r", code: 36))
        input.type("a")
        #expect(input.language == .english)
        #expect(input.committed == "AppあAaa")
        #expect(input.state == .none)
    }

    @MainActor @Test func mixedJapaneseAndEnglishEngine() {
        let input = EnglishInputSequence()
        input.type("nihongoApp")
        #expect(input.text == "日本語App")
        input.key(englishEvent(nil, code: 104))
        input.type("wotukau")
        #expect(input.text == "日本語Appを使う")
        input.key(englishEvent("\r", code: 36))
        #expect(input.committed == "日本語Appを使う")
        #expect(!input.marked)
        #expect(input.state == .none)
    }

    @MainActor @Test func digitBackspaceThenKanaMatchesEngineBaseline() {
        let input = EnglishInputSequence()
        input.type("App1")
        #expect(input.text == "App1")
        input.key(englishEvent("\u{7f}", code: 51))
        #expect(input.text == "App")
        #expect(input.marked)
        input.key(englishEvent(nil, code: 104))
        input.type("a")
        #expect(input.text == "Appあ")
    }

    @MainActor @Test func shiftSymbolDoesNotStartAndNormalEnglishStaysDirect() {
        let input = EnglishInputSequence()
        input.key(englishEvent("!", flags: [.shift], code: 18))
        #expect(input.text == "！")
        #expect(!input.marked)
        #expect(input.language == .japanese)
        let english = EnglishInputSequence()
        english.language = .english
        english.type("Apple")
        #expect(english.committed == "Apple")
        #expect(english.state == .none)
        #expect(!english.marked)
    }

    @MainActor @Test func navigationFunctionAndExternalStateChangeClearMark() {
        let input = EnglishInputSequence()
        input.type("App")
        input.key(englishEvent(nil, code: 125))
        #expect(input.state == .selecting)
        #expect(!input.marked)
        let function = EnglishInputSequence()
        function.type("App")
        function.key(englishEvent(nil, code: 97))
        #expect(function.state == .none)
        #expect(!function.marked)
        for state: InputState in [.none, .previewing, .selecting, .replaceSuggestion, .unicodeInput("")] {
            #expect(!TemporaryEnglishInput.isActive(true, inputState: state))
        }
        #expect(!TemporaryEnglishInput.markAfterAction(true, action: .selectInputLanguage(.japanese), inputState: .composing))
    }

    @MainActor @Test func shiftAloneAndShortcutKeepExistingComposition() {
        let input = EnglishInputSequence()
        input.type("App")
        // 修飾キー単押しは通常サーバーへ届かない。文字のないイベントでも変更しない。
        input.key(englishEvent(nil, flags: [.shift], code: 56))
        input.key(englishEvent("c", flags: [.command], code: 8))
        #expect(input.text == "App")
        #expect(input.committed.isEmpty)
        #expect(input.marked)
        #expect(input.state == .composing)
        input.type("a")
        #expect(input.text == "Appa")
    }

    @Test(arguments: [UInt16(97), 98, 100, 101, 109])
    func allFunctionKeysEndTemporaryInput(code: UInt16) {
        let event = englishEvent(nil, code: code)
        let userAction = UserAction.getUserAction(eventCore: event, inputLanguage: .english)
        let (action, callback) = InputState.composing.event(
            eventCore: event, userAction: userAction, inputLanguage: .english,
            liveConversionEnabled: true, enableDebugWindow: false, enableSuggestion: false
        )
        guard case .transition(let state) = callback else {
            Issue.record("Function key must finish composition")
            return
        }
        #expect(state == .none)
        #expect(!TemporaryEnglishInput.markAfterAction(true, action: action, inputState: state))
    }

    @MainActor @Test func debugSelectionDoesNotLeaveMark() {
        let input = EnglishInputSequence()
        input.manager.insertAtCursorPosition("あ", inputStyle: .direct)
        input.state = .selecting
        input.key(englishEvent("D", flags: [.shift]), debug: true)
        #expect(input.state == .selecting)
        #expect(!input.marked)
        #expect(input.committed.isEmpty)
    }
}
