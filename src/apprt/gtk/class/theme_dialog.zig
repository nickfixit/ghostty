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
const ThemeOverride = @import("../../../config/ThemeOverride.zig");
const ext = @import("../ext.zig");
const log = std.log.scoped(.gtk_theme_dialog);

const Context = struct {
    surface: *Surface,
    dropdown: *gtk.DropDown,
    model: *gtk.StringList,
    dialog: *adw.AlertDialog,
    original: ?ThemeOverride,
    previewed: bool = false,
};

const preview_body = "Select a theme to preview it in this terminal. Apply keeps it; Cancel restores your previous colours.";

pub fn present(surface: *Surface) !void {
    const core = surface.core() orelse return;
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
    // A selected theme can have been removed since it was loaded. Keep its
    // name visible so the initial selection still describes this terminal.
    if (core.theme_override) |theme| try names.put(try scratch.dupe(u8, theme.name), {});
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
    const dialog = adw.AlertDialog.new("Change Terminal Theme", preview_body);
    dialog.setExtraChild(dropdown.as(gtk.Widget));
    dialog.addResponse("cancel", "Cancel");
    dialog.addResponse("apply", "Apply");
    dialog.setResponseAppearance("apply", .suggested);
    dialog.setDefaultResponse("apply");
    dialog.setCloseResponse("cancel");

    const ctx = try alloc.create(Context);
    errdefer alloc.destroy(ctx);
    const original: ?ThemeOverride = if (core.theme_override) |theme| try theme.clone(alloc) else null;
    ctx.* = .{
        .surface = surface.ref(),
        .dropdown = dropdown,
        .model = model,
        .dialog = dialog,
        .original = original,
    };
    // Hold the widgets through chooseFinish, which may release the dialog.
    _ = dropdown.as(gobject.Object).ref();
    _ = model.as(gobject.Object).ref();
    _ = dialog.as(gobject.Object).ref();
    _ = gobject.Object.signals.notify.connect(
        dropdown,
        *Context,
        selectionChanged,
        ctx,
        .{ .detail = "selected" },
    );
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
    defer ctx.dropdown.as(gobject.Object).unref();
    defer ctx.model.as(gobject.Object).unref();
    defer ctx.dialog.as(gobject.Object).unref();
    defer if (ctx.original) |*theme| theme.deinit(Application.default().allocator());
    _ = gobject.signalHandlersDisconnectMatched(
        ctx.dropdown.as(gobject.Object),
        .{ .data = true },
        0,
        0,
        null,
        null,
        ctx,
    );
    const choice = ctx.dialog.chooseFinish(result);
    if (std.mem.eql(u8, std.mem.span(choice), "apply") or !ctx.previewed) return;
    const core = ctx.surface.core() orelse return;
    const base = Application.default().getConfig();
    defer base.unref();
    core.swapThemeOverride(&ctx.original, base.get()) catch |err| {
        log.warn("unable to restore theme after preview: {}", .{err});
    };
}

fn selectionChanged(_: *gtk.DropDown, _: *gobject.ParamSpec, ctx: *Context) callconv(.c) void {
    const core = ctx.surface.core() orelse return;
    const index = ctx.dropdown.getSelected();
    const name: ?[]const u8 = if (index == 0) null else std.mem.span(ctx.model.getString(index) orelse return);
    const base = Application.default().getConfig();
    defer base.unref();
    core.setThemeOverride(name, base.get()) catch |err| {
        log.warn("unable to preview theme: {}", .{err});
        ctx.dialog.setBody("Could not preview this theme: it is missing or contains invalid colours. Select another theme or Cancel to restore your previous colours.");
        ctx.dialog.setResponseEnabled("apply", 0);
        return;
    };
    ctx.previewed = true;
    ctx.dialog.setBody(preview_body);
    ctx.dialog.setResponseEnabled("apply", 1);
}
