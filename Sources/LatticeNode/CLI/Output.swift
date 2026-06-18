import Foundation

enum Style {
    static let cyan = "\u{001B}[36m"
    static let green = "\u{001B}[32m"
    static let yellow = "\u{001B}[33m"
    static let red = "\u{001B}[31m"
    static let bold = "\u{001B}[1m"
    static let dim = "\u{001B}[2m"
    static let reset = "\u{001B}[0m"
}

func printHeader(_ text: String) {
    print("\n\(Style.bold)\(Style.cyan)\(text)\(Style.reset)")
    print(String(repeating: "─", count: text.count))
}

func printKeyValue(_ key: String, _ value: String) {
    print("  \(Style.dim)\(key):\(Style.reset) \(value)")
}

func printSuccess(_ text: String) {
    print("\(Style.green)✓\(Style.reset) \(text)")
}

func printError(_ text: String) {
    print("\(Style.red)✗\(Style.reset) \(text)")
}

func printWarning(_ text: String) {
    print("\(Style.yellow)!\(Style.reset) \(text)")
}

func printLogo() {
    print("""
    \(Style.cyan)\(Style.bold)
      ╦  ┌─┐┌┬┐┌┬┐┬┌─┐┌─┐
      ║  ├─┤ │  │ ││  ├┤
      ╩═╝┴ ┴ ┴  ┴ ┴└─┘└─┘\(Style.reset)
    """)
}
