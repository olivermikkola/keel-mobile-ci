// Split literal Git separators, even when a following combining mark shares
// a Swift Character with '/'. Every resulting slice remains valid UTF-8.
func gitPathComponents(_ path: String) -> [String] {
    path.utf8.split(separator: 47, omittingEmptySubsequences: false)
        .map { String(decoding: $0, as: UTF8.self) }
}
