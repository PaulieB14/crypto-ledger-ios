import Foundation

var failures = 0

func check(_ condition: Bool, _ message: String) {
    if !condition {
        failures += 1
        FileHandle.standardError.write("FAIL \(message)\n".data(using: .utf8)!)
    }
}

check(ReviewPrompt.shouldAsk(currentVersion: "1.0.5", askedVersion: nil, succeeded: true), "first success asks")
check(!ReviewPrompt.shouldAsk(currentVersion: "1.0.5", askedVersion: nil, succeeded: false), "a failed import does not ask")
check(!ReviewPrompt.shouldAsk(currentVersion: "1.0.5", askedVersion: "1.0.5", succeeded: true), "same version does not ask twice")
check(ReviewPrompt.shouldAsk(currentVersion: "1.0.6", askedVersion: "1.0.5", succeeded: true), "the next version may ask once")
check(!ReviewPrompt.shouldAsk(currentVersion: "  ", askedVersion: nil, succeeded: true), "a blank version does not ask")
check(!ReviewPrompt.shouldAsk(currentVersion: "1.0.5", askedVersion: "1.0.5", succeeded: false), "failure still does not ask")

let suiteName = "ReviewPromptTests.\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: suiteName)!
defaults.removePersistentDomain(forName: suiteName)
check(ReviewPrompt.askedVersion(defaults: defaults) == nil, "fresh defaults have not asked")
ReviewPrompt.markAsked("1.0.5", defaults: defaults)
check(ReviewPrompt.askedVersion(defaults: defaults) == "1.0.5", "marks the version")
check(
    !ReviewPrompt.shouldAsk(currentVersion: "1.0.5", askedVersion: ReviewPrompt.askedVersion(defaults: defaults), succeeded: true),
    "stored version blocks a second ask"
)
ReviewPrompt.markAsked("  ", defaults: defaults)
check(ReviewPrompt.askedVersion(defaults: defaults) == "1.0.5", "a blank mark does not erase the version")
defaults.removePersistentDomain(forName: suiteName)

if failures > 0 {
    FileHandle.standardError.write("\(failures) failed\n".data(using: .utf8)!)
    exit(1)
}
print("review prompt: ok")
