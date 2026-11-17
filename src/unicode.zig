//! Default Unicode simple folding, xenoglyph's (CaseFolding.txt C and S).
//! Scalars map to one scalar; Turkic and expanding mappings are excluded.
//! Ill-formed bytes remain distinct.
const xenoglyph = @import("xenoglyph");

/// The canonical scalar in a default simple case-fold equivalence class.
pub fn fold(code: u21) u21 {
    if (code < 128) return if (code >= 'A' and code <= 'Z') code + 32 else code;
    return xenoglyph.case.simpleFold(code);
}

/// The least scalar at or after `code` that folds together with another, or
/// null past the last: a bracket range closes under folding by stepping from
/// one to the next.
pub fn nextFolding(code: u21) ?u21 {
    return xenoglyph.case.nextFolding(code);
}
