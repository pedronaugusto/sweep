//! Default Unicode simple folding. Scalars map to one scalar; Turkic and
//! expanding mappings are excluded. Ill-formed bytes remain distinct.
const data = @import("fold.zig");

/// Simple mappings, also used to close bracket ranges under folding.
pub const pairs = data.pairs;

/// The canonical scalar in a default simple case-fold equivalence class.
pub fn fold(code: u21) u21 {
    if (code < 128) return if (code >= 'A' and code <= 'Z') code + 32 else code;
    var lo: usize = 26;
    var hi: usize = pairs.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const pair = pairs[mid];
        if (code < pair.from) hi = mid else if (code > pair.from) lo = mid + 1 else return pair.to;
    }
    return code;
}
