//! Pictures built into the system, as encoded PNG bytes.

/// The granite shown behind the desktop when no other picture is chosen.
pub const granite = @embedFile("granite.png");

/// The granite at preview size, so Settings carries no full-size copy.
pub const granite_preview = @embedFile("granite-preview.png");
