const std = @import("std");

const canvas = @import("canvas.zig");
const draw = @import("draw.zig");
const font = @import("font.zig");
const image = @import("image.zig");
const style = @import("style.zig");
const text = @import("text.zig");
const theme = @import("theme.zig");

const Rect = canvas.Rect;
const Point = canvas.Point;
const List = draw.List;
const Style = style.Style;
const Text = text.Text;

const dot = 8;
const pitch = 14;
const caret = 2;
const thumb = 4;

pub const Size = struct {

    width: i32 = 0,
    height: i32 = 0,

};

/// What a node shows: children laid out by its style, one line of text, a text field, a wrapping text area, an image, or the app's own drawing.
pub const Content = union(enum) {

    box: []const *Node,
    label: []const u8,
    input: *Text,
    area: *Text,
    image: *image.Image,

    /// Records the node's drawing itself, inside its rectangle.
    custom: *const fn (*Node, *List) void,

};

/// The left button going down on a node, the pointer moving while it is held, and the button coming up; `at` is in surface coordinates.
pub const Track = struct {

    at: Point,
    phase: enum {

        down,
        move,
        up,

    },

};

/// The nodes a window highlights while drawing.
pub const Marks = struct {

    hover: ?*const Node = null,
    focus: ?*const Node = null,
    pressed: ?*const Node = null,

};

/// One element of a retained UI tree; the app owns every node and its window lays them out.
pub const Node = struct {

    style: Style = .{},
    content: Content = .{

        .box = &.{},

    },

    /// Runs on click, or on Space or Enter while focused; makes the node focusable.
    action: ?*const fn (*Node) void = null,

    /// Runs on double-click, or on Enter while focused, such as opening a file in a list.
    open: ?*const fn (*Node) void = null,

    /// Follows the pointer from a press on the node until release, such as drawing on a canvas.
    track: ?*const fn (*Node, Track) void = null,

    /// Free for the app, such as an index into its own data.
    data: usize = 0,

    hidden: bool = false,
    selected: bool = false,

    /// Shown with the `invalid` style until the user edits the node.
    invalid: bool = false,

    /// How far a scrolling container has scrolled, and how long its content runs, in pixels.
    offset: i32 = 0,
    extent: i32 = 0,

    /// Where the last layout put the node, in surface coordinates.
    rect: Rect = .{},

    pub fn focusable(self: *const Node) bool {

        return self.shown() and (self.action != null or self.open != null or self.editable());

    }

    pub fn editable(self: *const Node) bool {

        return self.content == .input or self.content == .area;

    }

    /// Visible after the last layout, so no hidden ancestor either.
    pub fn shown(self: *const Node) bool {

        return !self.hidden and self.rect.width > 0 and self.rect.height > 0;

    }

    pub fn typeface(self: *const Node) *const font.Font {

        return font.face(self.style.face);

    }

    /// The area inside the node's padding.
    pub fn inner(self: *const Node) Rect {

        return self.style.padding.shrink(self.rect);

    }

    // ponytail: containers re-measure children at each level, O(nodes x depth); cache sizes if trees grow deep.
    pub fn measure(self: *const Node) Size {

        if (self.hidden) return .{};

        const box = &self.style;
        var natural = Size{};

        switch (self.content) {

            // A scrolling container takes the room it is given rather than its content's.
            .box => |children| if (!box.scroll) {

                var count: i32 = 0;

                for (children) |child| {

                    if (child.hidden) continue;

                    const size = child.measure();

                    switch (box.direction) {

                        .row => {

                            natural.width += size.width;
                            natural.height = @max(natural.height, size.height);

                        },
                        .column => {

                            natural.width = @max(natural.width, size.width);
                            natural.height += size.height;

                        },
                        .stack => natural = .{

                            .width = @max(natural.width, size.width),
                            .height = @max(natural.height, size.height),

                        },

                    }

                    count += 1;

                }

                const gaps = box.gap * @max(count - 1, 0);

                if (box.direction == .row) natural.width += gaps else if (box.direction == .column) natural.height += gaps;

            },
            .label => |string| natural = .{

                .width = @intFromFloat(@ceil(self.typeface().measure(string, box.size / self.typeface().units))),
                .height = text.leading(self.typeface(), box.size),

            },
            .input, .area => natural.height = text.leading(self.typeface(), box.size),
            .image => |picture| natural = .{

                .width = @intCast(picture.width),
                .height = @intCast(picture.height),

            },
            .custom => {

            },

        }

        return .{

            .width = box.width orelse natural.width + box.padding.left + box.padding.right,
            .height = box.height orelse natural.height + box.padding.top + box.padding.bottom,

        };

    }

    /// Places the node and its children in `area`, growing `damage` by every rectangle that moved.
    pub fn arrange(self: *Node, area: Rect, damage: *Rect) void {

        const target = if (self.hidden) Rect{} else area;

        if (!std.meta.eql(self.rect, target)) {

            damage.* = damage.join(self.rect).join(target);
            self.rect = target;

        }

        const children = switch (self.content) {

            .box => |children| children,
            else => return,

        };

        const box = &self.style;
        const inner_area = box.padding.shrink(target);
        const row = box.direction == .row;

        if (box.direction == .stack) {

            for (children) |child| child.arrange(if (self.hidden) .{} else inner_area, damage);
            return;

        }
        const span = if (row) inner_area.width else inner_area.height;
        const across = if (row) inner_area.height else inner_area.width;
        var used: i32 = 0;
        var grow: i32 = 0;
        var count: i32 = 0;

        for (children) |child| {

            if (child.hidden) continue;

            const size = child.measure();

            used += if (row) size.width else size.height;
            grow += child.style.grow;
            count += 1;

        }

        used += box.gap * @max(count - 1, 0);

        // Scrolled content keeps its natural length and slides under the container.
        if (box.scroll) {

            self.extent = used;
            self.offset = std.math.clamp(self.offset, 0, @max(used - span, 0));
            grow = 0;

        }

        const free = if (box.scroll) 0 else @max(span - used, 0);
        var offset: i32 = if (box.scroll) -self.offset else if (grow != 0) 0 else switch (box.justify) {

            .center => @divTrunc(free, 2),
            .end => free,
            else => 0,

        };

        for (children) |child| {

            if (self.hidden or child.hidden) {

                child.arrange(.{}, damage);
                continue;

            }

            const size = child.measure();
            const fixed = if (row) child.style.height else child.style.width;
            const natural = if (row) size.height else size.width;
            const length = (if (row) size.width else size.height) + if (grow != 0) @divTrunc(free * child.style.grow, grow) else 0;
            const thickness = if (box.items == .stretch and fixed == null) across else @min(natural, across);
            const shift = switch (box.items) {

                .center => @divTrunc(across - thickness, 2),
                .end => across - thickness,
                else => 0,

            };

            child.arrange(if (row) .{

                .x = inner_area.x + offset,
                .y = inner_area.y + shift,
                .width = length,
                .height = thickness,

            } else .{

                .x = inner_area.x + shift,
                .y = inner_area.y + offset,
                .width = thickness,
                .height = length,

            }, damage);

            offset += length + box.gap;

        }

    }

    /// Records the node and its children inside the list limit; `under` is the colour already behind it.
    pub fn paint(self: *Node, target: *List, marks: Marks, under: u32) void {

        if (!self.shown()) return;
        if (target.limit) |limit| if (limit.intersect(self.rect) == null) return;

        const box = &self.style;
        const colors = box.paint(.{

            .hover = marks.hover == self,
            .selected = self.selected,
            .focus = marks.focus == self,
            .pressed = marks.pressed == self,
            .invalid = self.invalid,

        });
        const fill = colors.background orelse under;
        const color = colors.color orelse box.color;
        const inner_area = self.inner();
        const limit = target.limit;

        if (colors.border != null and box.border_width > 0) {

            target.round(self.rect, box.radius, colors.border.?);
            target.round(self.rect.inset(box.border_width), box.radius - box.border_width, fill);

        } else if (colors.background) |background| {

            target.round(self.rect, box.radius, background);

        }

        defer target.limit = limit;

        // Plain containers let children draw anywhere their own limit allows; everything else stays inside its rectangle.
        if (self.content != .box or box.scroll) target.limit = if (limit) |outer| outer.intersect(self.rect) orelse return else self.rect;

        switch (self.content) {

            .box => |children| {

                for (children) |child| child.paint(target, marks, fill);
                if (box.scroll) self.bar(target);

            },
            .label => |string| target.label(string, box.face, box.size, inner_area, color, box.text_align),
            .input => |edit| self.line(edit, target, inner_area, color, marks.focus == self),
            .area => |edit| self.lines(edit, target, inner_area, color, marks.focus == self),
            .image => |picture| target.image(picture.handle, picture.place(inner_area)),
            .custom => |record| record(self, target),

        }

    }

    /// The deepest focusable or tracking node under `point`.
    pub fn hit(self: *Node, point: Point) ?*Node {

        if (!self.shown() or !self.rect.contains(point)) return null;

        if (self.content == .box) {

            const children = self.content.box;

            // Stacked children draw in order, so the last one is on top.
            for (0..children.len) |index| {

                const child = children[if (self.style.direction == .stack) children.len - 1 - index else index];

                if (child.hit(point)) |found| return found;

            }

        }

        return if (self.focusable() or self.track != null) self else null;

    }

    /// Scrolls the deepest scrolling node under `point` by `delta` pixels; returns it, or null when nothing moved.
    pub fn wheel(self: *Node, point: Point, delta: i32) ?*Node {

        if (!self.shown() or !self.rect.contains(point)) return null;

        switch (self.content) {

            .box => |children| {

                for (children) |child| {

                    if (child.wheel(point, delta)) |found| return found;

                }

                if (!self.style.scroll) return null;

                const span = if (self.style.direction == .row) self.inner().width else self.inner().height;
                const moved = std.math.clamp(self.offset + delta, 0, @max(self.extent - span, 0));

                if (moved == self.offset) return null;
                self.offset = moved;

                return self;

            },
            .area => |edit| {

                const height = text.leading(self.typeface(), self.style.size);
                const count: i32 = @divTrunc(delta, height);
                const top = @max(@as(i64, @intCast(edit.top)) + if (count == 0) std.math.sign(delta) else count, 0);

                if (top == edit.top) return null;

                // The next paint clamps it to the text.
                edit.top = @intCast(top);
                edit.mark = edit.caret;

                return self;

            },
            else => return null,

        }

    }

    /// Scrolls every scrolling ancestor of `target` so it shows; true when `target` is under this node.
    pub fn reveal(self: *Node, target: *const Node) bool {

        if (self == target) return true;
        if (self.content != .box) return false;

        for (self.content.box) |child| {

            if (!child.reveal(target)) continue;
            if (!self.style.scroll) return true;

            const row = self.style.direction == .row;
            const view = self.inner();
            const start = if (row) target.rect.x - view.x else target.rect.y - view.y;
            const length = if (row) target.rect.width else target.rect.height;
            const span = if (row) view.width else view.height;

            if (start < 0) self.offset += start else if (start + length > span) self.offset += @min(start + length - span, start);

            return true;

        }

        return false;

    }

    /// Appends the focusable nodes in tree order to `list`, returning how many there are.
    pub fn collect(self: *Node, list: []*Node, count: usize) usize {

        if (!self.shown()) return count;

        var total = count;

        if (self.focusable() and total < list.len) {

            list[total] = self;
            total += 1;

        }

        if (self.content == .box) {

            for (self.content.box) |child| total = child.collect(list, total);

        }

        return total;

    }

    /// The caret position under `point` in a text field or area.
    pub fn locate(self: *const Node, point: Point) usize {

        const edit = switch (self.content) {

            .input, .area => |edit| edit,
            else => return 0,

        };

        const area = self.inner();
        const x: f32 = @floatFromInt(point.x - area.x + if (self.content == .input) edit.left else 0);

        if (self.content == .input) {

            if (edit.secret) return @min(@as(usize, @intCast(@max(@divTrunc(point.x - area.x + pitch / 2, pitch), 0))), edit.length);

            return edit.locate(self.typeface(), self.style.size, area.width, x, null);

        }

        const row = edit.top + @as(usize, @intCast(@max(@divTrunc(point.y - area.y, text.leading(self.typeface(), self.style.size)), 0)));

        return edit.locate(self.typeface(), self.style.size, area.width, x, row);

    }

    /// Wrapped lines that fit in a text area.
    pub fn rows(self: *const Node) i32 {

        return @max(@divTrunc(self.inner().height, text.leading(self.typeface(), self.style.size)), 1);

    }

    /// A thin thumb showing where a scrolling container sits in its content.
    fn bar(self: *const Node, target: *List) void {

        const row = self.style.direction == .row;
        const span = if (row) self.rect.width else self.rect.height;
        if (self.extent <= span or span <= 0) return;

        const length = @max(@divTrunc(span * span, self.extent), 24);
        const start = @divTrunc((span - length) * self.offset, @max(self.extent - span, 1));

        target.round(if (row) .{

            .x = self.rect.x + start,
            .y = self.rect.bottom() - thumb - 2,
            .width = length,
            .height = thumb,

        } else .{

            .x = self.rect.right() - thumb - 2,
            .y = self.rect.y + start,
            .width = thumb,
            .height = length,

        }, thumb / 2, theme.faint);

    }

    fn line(self: *const Node, edit: *Text, target: *List, area: Rect, color: u32, focused: bool) void {

        const box = &self.style;
        const face = self.typeface();
        const scale = box.size / face.units;
        const height = text.leading(face, box.size);
        const top = area.y + @divTrunc(area.height - height, 2);

        if (edit.length == 0) {

            edit.left = 0;
            target.label(edit.placeholder, box.face, box.size, area, box.muted, box.text_align);

        } else if (edit.secret) {

            edit.left = 0;

            for (0..@min(edit.length, @as(usize, @intCast(@max(@divTrunc(area.width, pitch), 0))))) |index| {

                target.round(.{

                    .x = area.x + @as(i32, @intCast(index)) * pitch + 2,
                    .y = area.y + @divTrunc(area.height - dot, 2),
                    .width = dot,
                    .height = dot,

                }, dot / 2, color);

            }

        } else {

            const position: i32 = @intFromFloat(face.measure(edit.buffer[0..edit.caret], scale));

            // Keep the caret in view as it moves past either edge.
            if (position - edit.left > area.width - caret) edit.left = position - area.width + caret;
            if (position < edit.left) edit.left = position;

            if (edit.selection()) |range| {

                const start: i32 = @intFromFloat(face.measure(edit.buffer[0..range.start], scale));
                const end: i32 = @intFromFloat(face.measure(edit.buffer[0..range.end], scale));

                target.fill(.{

                    .x = area.x + start - edit.left,
                    .y = top,
                    .width = end - start,
                    .height = height,

                }, theme.selected);

            }

            target.text(edit.text(), box.face, box.size, area.x - edit.left, canvas.anchor(face, "", box.size, area, .left).y, color);

        }

        if (!focused) return;

        const offset: i32 = if (edit.secret) @intCast(edit.caret * pitch) else @as(i32, @intFromFloat(face.measure(edit.buffer[0..edit.caret], scale))) - edit.left;

        target.fill(.{

            .x = area.x + offset,
            .y = top,
            .width = caret,
            .height = height,

        }, box.focus.border orelse color);

    }

    fn lines(self: *const Node, edit: *Text, target: *List, area: Rect, color: u32, focused: bool) void {

        const box = &self.style;
        const face = self.typeface();
        const scale = box.size / face.units;
        const height = text.leading(face, box.size);
        const count: usize = @intCast(self.rows());
        const string = edit.text();
        const range = edit.selection();

        if (edit.length == 0) {

            target.text(edit.placeholder, box.face, box.size, area.x, area.y + baseline(face, box.size), box.muted);

        }

        var wrapped = text.Lines.init(face, string, box.size, area.width);
        var index: usize = 0;
        var total: usize = 0;

        // Scroll so the caret's line shows after it moves, and never past the end.
        while (wrapped.next()) |span| : (index += 1) {

            total += 1;
            if (edit.mark == edit.caret or !span.holds(string, edit.caret)) continue;

            if (index < edit.top) edit.top = index;
            if (index >= edit.top + count) edit.top = index + 1 - count;

        }

        edit.mark = edit.caret;
        edit.top = @min(edit.top, total -| count);
        wrapped = text.Lines.init(face, string, box.size, area.width);
        index = 0;

        while (wrapped.next()) |span| : (index += 1) {

            if (index < edit.top) continue;
            if (index >= edit.top + count) break;

            const y = area.y + @as(i32, @intCast(index - edit.top)) * height;

            if (range) |selected| if (selected.start <= span.end and selected.end >= span.start and selected.start != selected.end) {

                const start = @max(selected.start, span.start);
                const end = @min(selected.end, span.end);
                const left: i32 = @intFromFloat(face.measure(string[span.start..start], scale));
                const right: i32 = @intFromFloat(face.measure(string[span.start..end], scale));

                // A selected line break shows as a sliver past the line's end.
                target.fill(.{

                    .x = area.x + left,
                    .y = y,
                    .width = right - left + if (selected.end > span.end) @as(i32, 6) else 0,
                    .height = height,

                }, theme.selected);

            };

            target.text(string[span.start..span.end], box.face, box.size, area.x, y + baseline(face, box.size), color);

            if (focused and span.holds(string, edit.caret)) target.fill(.{

                .x = area.x + @as(i32, @intFromFloat(face.measure(string[span.start..edit.caret], scale))),
                .y = y,
                .width = caret,
                .height = height,

            }, box.focus.border orelse color);

        }

    }

};

fn baseline(face: *const font.Font, size: f32) i32 {

    return @intFromFloat(@as(f32, @floatFromInt(face.ascent)) * size / face.units);

}
