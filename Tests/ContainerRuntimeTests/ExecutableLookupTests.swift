import Testing
@testable import ContainerRuntime

@Test(arguments: [
    // Explicit paths bypass PATH; relative ones stay relative to the cwd.
    ("/bin/sh", ["PATH=/usr/bin"], ["/bin/sh"], false),
    ("./run", ["PATH=/usr/bin"], ["./run"], false),
    ("bin/run", [], ["bin/run"], false),
    ("/usr//bin/../sh", ["PATH=/x"], ["/usr//bin/../sh"], false),
    // Bare names search PATH in order with Go's lexical join.
    ("sh", ["PATH=/usr/local/bin:/usr/bin/:/bin"], ["/usr/local/bin/sh", "/usr/bin/sh", "/bin/sh"], true),
    ("sh", ["PATH=/a//b/./c/../d"], ["/a/b/d/sh"], true),
    // Empty elements mean "."; relative elements stay relative.
    ("sh", ["PATH=:/bin:"], ["sh", "/bin/sh", "sh"], true),
    ("sh", ["PATH=bin:./tools:../up"], ["bin/sh", "tools/sh", "../up/sh"], true),
    // A missing or empty PATH has no candidates at all.
    ("sh", [], [], true),
    ("sh", ["PATH="], [], true),
    ("sh", ["HOME=/root", "XPATH=/bin", "PATHS=/bin"], [], true),
    // The last PATH wins if the caller did not deduplicate.
    ("sh", ["PATH=/first", "PATH=/second"], ["/second/sh"], true),
    // A name that cleans to its directory is still only a candidate.
    ("..", ["PATH=/bin"], ["/"], true),
    // Separators are bytes even before a combining mark (U+0301).
    ("sh", ["PATH=/a:\u{301}b"], ["/a/sh", "\u{301}b/sh"], true),
    ("sh", ["PATH=\u{301}/x"], ["\u{301}/x/sh"], true),
])
func executableLookupCandidates(_ name: String, _ environment: [String], _ candidates: [String], _ searchesPath: Bool) {
    let lookup = ExecutableLookup(name: name, environment: environment)
    #expect(lookup.candidates == candidates)
    #expect(lookup.searchesPath == searchesPath)
}

@Test(arguments: [
    ("", "."), ("/", "/"), ("//", "/"), ("a/", "a"), ("./a", "a"), ("a/..", "."),
    ("../a", "../a"), ("a/../../b", "../b"), ("/../a", "/a"), ("/a/b/../../..", "/"),
])
func executableLookupCleansLikeGo(_ path: String, _ expected: String) {
    #expect(ExecutableLookup.clean(path) == expected)
}
