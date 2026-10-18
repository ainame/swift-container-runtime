/// Go-compatible diagnostic quoting, distinct from JSON encoding.
enum GoText {
    /// Go's %q for the ASCII-safe texts this runtime reports.
    static func quote(_ text: String) -> String {
        var result = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\t": result += "\\t"
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }
}
