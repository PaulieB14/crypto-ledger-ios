import Foundation

// Every case below is a number a person could type on the decimal pad their
// locale gives them. The German ones are the regression: reported 2026-08-29
// with a screenshot of "0,5" leaving the Add button disabled.
let cases: [(String, String, String)] = [
    // input        locale     expected ("nil" = must be rejected, not guessed at)
    ("0,5",         "de_DE",   "0.5"),
    ("0,5",         "en_US",   "0.5"),      // comma typed in a dot locale still means a half
    ("0.5",         "de_DE",   "0.5"),      // and vice versa
    ("0.5",         "en_US",   "0.5"),
    ("1,5",         "de_DE",   "1.5"),      // silently became 1 before this
    ("1.234,56",    "de_DE",   "1234.56"),
    ("1,234.56",    "en_US",   "1234.56"),
    ("1.234",       "de_DE",   "1234"),     // grouping, not 1.234
    ("1,234",       "en_US",   "1234"),
    ("1 234,56",    "de_DE",   "1234.56"),  // space grouping
    ("1'234.56",    "de_CH",   "1234.56"),  // Swiss apostrophe grouping
    ("-2,5",        "de_DE",   "-2.5"),
    (",5",          "de_DE",   "0.5"),
    ("0,00000001",  "de_DE",   "0.00000001"),
    ("1234",        "en_US",   "1234"),
    ("78903",       "de_DE",   "78903"),
    ("",            "en_US",   "nil"),
    ("abc",         "en_US",   "nil"),
    ("1,2,3",       "de_DE",   "nil"),      // not valid grouping, not one decimal
]

var failures = 0
for (input, localeID, expected) in cases {
    let got = UserNumber.decimal(input, locale: Locale(identifier: localeID)).map { "\($0)" } ?? "nil"
    if got != expected {
        failures += 1
        FileHandle.standardError.write("FAIL \(localeID) \"\(input)\" -> \(got), expected \(expected)\n".data(using: .utf8)!)
    }
}
if failures == 0 {
    print("UserNumber: \(cases.count) cases passed")
} else {
    FileHandle.standardError.write("\(failures) of \(cases.count) failed\n".data(using: .utf8)!)
    exit(1)
}
