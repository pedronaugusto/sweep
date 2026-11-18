//! sweep's test data: the Unicode Character Database's NormalizationTest.txt and CaseFolding.txt
//! (under UNICODE-LICENSE.txt) and the pattern corpora syntax.tsv and captures.tsv. It stays out of
//! src/ and of the package a project fetches (build.zig.zon's paths), and reaches the tests only as
//! the development build's module `testdata`.

/// The file at `path` under testdata/, embedded: `file("CaseFolding.txt")`.
pub fn file(comptime path: []const u8) @TypeOf(@embedFile(path)) {
    return @embedFile(path);
}
