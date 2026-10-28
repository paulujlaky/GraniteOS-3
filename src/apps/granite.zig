//! The granite picture shown behind the desktop when no other is chosen.

const std = @import("std");

const gui = @import("gui");
const pictures = @import("pictures");

/// Decodes the granite picture using `allocator`'s scratch space; publish it to show it.
pub fn load(allocator: std.mem.Allocator) !gui.Image {

    return gui.Image.decode(allocator, pictures.granite);

}

/// Decodes the granite picture at preview size, so Settings carries no full-size copy.
pub fn preview(allocator: std.mem.Allocator) !gui.Image {

    return gui.Image.decode(allocator, pictures.granite_preview);

}
