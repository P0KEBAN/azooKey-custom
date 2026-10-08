public enum TemporaryEnglishInput {
    public static func shouldStart(event: KeyEventCore, inputLanguage: InputLanguage, inputState: InputState) -> Bool {
        guard inputLanguage == .japanese, event.modifierFlags == [.shift],
              let characters = event.characters, characters.utf8.count == 1,
              let letter = characters.utf8.first, (65...90).contains(letter) else {
            return false
        }
        switch inputState {
        case .none, .composing, .previewing, .selecting:
            return true
        case .attachDiacritic, .replaceSuggestion, .unicodeInput:
            return false
        }
    }

    public static func isActive(_ marked: Bool, inputState: InputState) -> Bool {
        marked && inputState == .composing
    }

    public static func interpretationLanguage(starting: Bool, active: Bool, inputLanguage: InputLanguage) -> InputLanguage {
        starting || active ? .english : inputLanguage
    }

    public static func resolveAction(
        _ action: ClientAction,
        callback: ClientActionCallback,
        starting: Bool,
        active: Bool,
        inputState: InputState
    ) -> (ClientAction, ClientActionCallback) {
        if starting, inputState == .none, case .insertWithoutMarkedText(let text) = action {
            return (.appendToMarkedText(text), .transition(.composing))
        }
        if active, case .acceptPredictionCandidate = action {
            return (.consume, .fallthrough)
        }
        return (action, callback)
    }

    public static func markAfterAction(_ marked: Bool, action: ClientAction, inputState: InputState) -> Bool {
        switch action {
        case .selectInputLanguage, .commitMarkedTextAndSelectInputLanguage:
            return false
        default:
            return isActive(marked, inputState: inputState)
        }
    }
}
