const std = @import("std");
const builtin = @import("builtin");
const terminal = @import("shared/terminal.zig");
const cli_parser = @import("cli/parser.zig");
const cli_help = @import("cli/help.zig");
const runner = @import("app/runner.zig");

/// Windows: 将控制台输入/输出代码页设为 UTF-8 (65001)，解决中文乱码
fn setupConsole() void {
    if (builtin.os.tag != .windows) return;
    const windows = struct {
        extern "kernel32" fn SetConsoleOutputCP(wCodePageID: u32) i32;
        extern "kernel32" fn SetConsoleCP(wCodePageID: u32) i32;
    };
    _ = windows.SetConsoleOutputCP(65001);
    _ = windows.SetConsoleCP(65001);
}

pub fn main(init: std.process.Init) !void {
    setupConsole();

    const io = init.io;
    const allocator = init.gpa;

    // Collect args into a slice
    var args_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args_list.deinit(allocator);

    var args_iter = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args_iter.deinit();
    _ = args_iter.next(); // skip prog name
    while (args_iter.next()) |arg| {
        try args_list.append(allocator, arg);
    }

    if (args_list.items.len == 0) {
        cli_help.printHelp(io);
        return;
    }

    const cli = cli_parser.parseArgsList(args_list.items) catch |err| {
        terminal.logError(io, "参数解析失败: {}", .{err});
        return;
    };

    if (cli.debug) {
        terminal.setLogLevel(.debug);
    }

    if (cli.action == null) {
        cli_help.printHelp(io);
        return;
    }

    try runner.run(init, cli);
}
