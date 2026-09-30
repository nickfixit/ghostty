//! A terminal-local colour selection. Only value-type colour fields cross
//! this boundary: a theme cannot change commands, bindings or window settings.
const ThemeOverride = @This();
const std = @import("std");
const Config = @import("Config.zig");
const theme = @import("theme.zig");

name: [:0]const u8,
colors: Colors,

pub const Colors = struct {
    background: @FieldType(Config, "background"),
    foreground: @FieldType(Config, "foreground"),
    palette: @FieldType(Config, "palette"),
    @"cursor-color": @FieldType(Config, "cursor-color"),
    @"cursor-text": @FieldType(Config, "cursor-text"),
    @"selection-background": @FieldType(Config, "selection-background"),
    @"selection-foreground": @FieldType(Config, "selection-foreground"),
    @"search-background": @FieldType(Config, "search-background"),
    @"search-foreground": @FieldType(Config, "search-foreground"),
    @"search-selected-background": @FieldType(Config, "search-selected-background"),
    @"search-selected-foreground": @FieldType(Config, "search-selected-foreground"),
    @"bold-color": @FieldType(Config, "bold-color"),

    pub fn fromConfig(config: *const Config) Colors {
        var result: Colors = undefined;
        inline for (@typeInfo(Colors).@"struct".fields) |field| {
            @field(result, field.name) = @field(config, field.name);
        }
        return result;
    }

    pub fn apply(self: Colors, config: *Config) void {
        inline for (@typeInfo(Colors).@"struct".fields) |field| {
            @field(config, field.name) = @field(self, field.name);
        }
    }
};

pub fn load(alloc: std.mem.Allocator, name: []const u8) !ThemeOverride {
    var config = try Config.default(alloc);
    defer config.deinit();
    const opened = (try theme.open(config._arena.?.allocator(), name, &config._diagnostics)) orelse
        return error.ThemeNotFound;
    defer opened.file.close();
    var buffer: [4096]u8 = undefined;
    var reader = opened.file.reader(&buffer);
    var lines: @import("../cli.zig").args.LineIterator = .{
        .r = &reader.interface,
        .filepath = opened.path,
    };
    try loadColors(&config, alloc, &lines);
    if (!config._diagnostics.empty()) return error.InvalidTheme;
    return .{ .name = try alloc.dupeZ(u8, name), .colors = Colors.fromConfig(&config) };
}

fn loadColors(config: *Config, alloc: std.mem.Allocator, iter: anytype) !void {
    while (iter.next()) |arg| {
        const key_end = std.mem.indexOfScalar(u8, arg, '=') orelse continue;
        const key = std.mem.trimStart(u8, arg[0..key_end], "-");
        inline for (@typeInfo(Colors).@"struct".fields) |field| {
            if (std.mem.eql(u8, key, field.name)) {
                var single = @import("../cli.zig").args.sliceIterator(&.{arg});
                try config.loadIter(alloc, &single);
            }
        }
    }
}

pub fn deinit(self: *ThemeOverride, alloc: std.mem.Allocator) void {
    alloc.free(self.name);
    self.* = undefined;
}

test "ThemeOverride changes colours without importing theme commands" {
    const alloc = std.testing.allocator;
    var source = try Config.default(alloc);
    defer source.deinit();
    var iter = @import("../cli.zig").args.sliceIterator(&.{
        "--background=112233", "--foreground=aabbcc",   "--palette=1=#123456",
        "--font-size=99",      "--command=bad-command", "--config-file=/missing",
    });
    try loadColors(&source, alloc, &iter);
    try std.testing.expect(source._diagnostics.empty());
    try std.testing.expect(source.command == null);

    var target = try Config.default(alloc);
    defer target.deinit();
    target.@"font-size" = 17;
    target.@"background-opacity" = 0.8;
    Colors.fromConfig(&source).apply(&target);
    try std.testing.expectEqual(Config.Color{ .r = 0x11, .g = 0x22, .b = 0x33 }, target.background);
    try std.testing.expectEqual(@as(f32, 17), target.@"font-size");
    try std.testing.expectEqual(@as(f64, 0.8), target.@"background-opacity");
    try std.testing.expect(target.command == null);
}

test "ThemeOverride loads colour files and rejects missing or invalid themes" {
    const alloc = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    try dir.dir.writeFile(.{
        .sub_path = "valid",
        .data = "background = #112233\nforeground = #aabbcc\npalette = 1=#123456\ncommand = bad-command\nfont-size = 99\n",
    });
    const path = try dir.dir.realpathAlloc(alloc, "valid");
    defer alloc.free(path);
    var loaded = try load(alloc, path);
    defer loaded.deinit(alloc);
    try std.testing.expectEqual(Config.Color{ .r = 0x11, .g = 0x22, .b = 0x33 }, loaded.colors.background);
    try std.testing.expectEqual(@import("../terminal/color.zig").RGB{ .r = 0x12, .g = 0x34, .b = 0x56 }, loaded.colors.palette.value[1]);
    try dir.dir.writeFile(.{ .sub_path = "valid", .data = "background = invalid-colour\n" });
    try std.testing.expectError(error.InvalidTheme, load(alloc, path));
    try dir.dir.deleteFile("valid");
    try std.testing.expectError(error.ThemeNotFound, load(alloc, path));
}

test "ThemeOverride leaves sibling config intact and replaces omitted colours" {
    const alloc = std.testing.allocator;
    var base = try Config.default(alloc);
    defer base.deinit();
    var first = Colors.fromConfig(&base);
    first.background = .{ .r = 1, .g = 2, .b = 3 };
    first.@"cursor-color" = .{ .color = .{ .r = 4, .g = 5, .b = 6 } };
    var selected = try base.clone(alloc);
    defer selected.deinit();
    first.apply(&selected);
    try std.testing.expect(!std.meta.eql(base.background, selected.background));
    try std.testing.expect(base.@"cursor-color" == null);
    Colors.fromConfig(&base).apply(&selected);
    try std.testing.expectEqualDeep(base.background, selected.background);
    try std.testing.expect(selected.@"cursor-color" == null);
}
