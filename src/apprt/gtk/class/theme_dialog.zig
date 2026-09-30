//! Searchable colour picker for one terminal. The surface is held while the
//! dialog is open, but its core may disappear (for example if a child exits).
const std = @import("std");
const adw = @import("adw");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");
const Surface = @import("surface.zig").Surface;
const Application = @import("application.zig").Application;
const themes = @import("../../../config/theme.zig");
const ext = @import("../ext.zig");
const log = std.log.scoped(.gtk_theme_dialog);

const Context = struct {
    surface: *Surface,
    dropdown: *gtk.DropDown,
    model: *gtk.StringList,
    dialog: *adw.AlertDialog,
};

pub fn present(surface: *Surface) !void {
    const alloc = Application.default().allocator();
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const scratch = arena.allocator();
    var names: std.StringHashMap(void) = .init(scratch);
    var locations: themes.LocationIterator = .{ .arena_alloc = scratch };
    while (try locations.next()) |location| {
        var dir = std.fs.cwd().openDir(location.dir, .{ .iterate = true }) catch continue;
        defer dir.close();
        var entries = dir.iterate();
        while (try entries.next()) |entry| {
            if (entry.kind != .file and entry.kind != .sym_link) continue;
            if (std.mem.startsWith(u8, entry.name, ".")) continue;
            try names.put(try scratch.dupe(u8, entry.name), {});
        }
    }
    var sorted: std.ArrayList([]const u8) = .empty;
    var keys = names.keyIterator();
    while (keys.next()) |key| try sorted.append(scratch, key.*);
    std.mem.sort([]const u8, sorted.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.ascii.orderIgnoreCase(a, b) == .lt;
        }
    }.less);

    const model = gtk.StringList.new(null);
    defer model.as(gobject.Object).unref();
    model.append("Use configured theme");
    var selected: c_uint = 0;
    const core = surface.core() orelse return;
    for (sorted.items, 1..) |name, index| {
        model.append(try scratch.dupeZ(u8, name));
        if (core.theme_override) |theme| {
            if (std.mem.eql(u8, theme.name, name)) selected = @intCast(index);
        }
    }

    // DropDown.new consumes a model reference.
    _ = model.as(gobject.Object).ref();
    const expression = gtk.PropertyExpression.new(gtk.StringObject.getGObjectType(), null, "string");
    const dropdown = gtk.DropDown.new(model.as(gio.ListModel), expression.as(gtk.Expression));
    dropdown.setEnableSearch(1);
    dropdown.setSelected(selected);
    const dialog = adw.AlertDialog.new("Change Terminal Theme", "Applies to this terminal only, for this session.");
    dialog.setExtraChild(dropdown.as(gtk.Widget));
    dialog.addResponse("cancel", "Cancel");
    dialog.addResponse("apply", "Apply");
    dialog.setResponseAppearance("apply", .suggested);
    dialog.setDefaultResponse("apply");
    dialog.setCloseResponse("cancel");

    const ctx = try alloc.create(Context);
    ctx.* = .{ .surface = surface.ref(), .dropdown = dropdown, .model = model, .dialog = dialog };
    const parent: *gtk.Widget = if (ext.getAncestor(adw.ApplicationWindow, surface.as(gtk.Widget))) |win|
        win.as(gtk.Widget)
    else
        surface.as(gtk.Widget);
    dialog.choose(parent, null, response, ctx);
}

fn response(_: ?*gobject.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
    const ctx: *Context = @ptrCast(@alignCast(data));
    defer Application.default().allocator().destroy(ctx);
    defer ctx.surface.unref();
    const choice = ctx.dialog.chooseFinish(result);
    if (!std.mem.eql(u8, std.mem.span(choice), "apply")) return;
    const core = ctx.surface.core() orelse return;
    const index = ctx.dropdown.getSelected();
    const name: ?[]const u8 = if (index == 0) null else std.mem.span(ctx.model.getString(index) orelse return);
    const base = Application.default().getConfig();
    defer base.unref();
    core.setThemeOverride(name, base.get()) catch |err| {
        log.warn("unable to apply theme: {}", .{err});
        const error_dialog = adw.AlertDialog.new("Could Not Apply Theme", "The theme is missing or contains invalid colours. Your previous theme is unchanged.");
        error_dialog.addResponse("close", "Close");
        error_dialog.setCloseResponse("close");
        error_dialog.as(adw.Dialog).present(ctx.surface.as(gtk.Widget));
    };
}
