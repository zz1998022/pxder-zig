//! 终端 UI 模块
//! 提供 ANSI 颜色输出、进度条、日志打印等功能。
//! 所有输出函数都需要传入 io 实例（Zig 0.16 的 I/O 模型要求）。

const std = @import("std");

/// 支持的终端颜色
pub const Color = enum {
    reset,
    red,
    green,
    yellow,
    cyan,
    gray,
    white,
    bg_red, // 背景色：用于下载失败标记
    bg_yellow, // 背景色：用于重试标记
    bg_magenta,
};

/// 获取颜色对应的 ANSI 转义序列
pub fn colorCode(c: Color) []const u8 {
    return switch (c) {
        .reset => "\x1b[0m",
        .red => "\x1b[31m",
        .green => "\x1b[32m",
        .yellow => "\x1b[33m",
        .cyan => "\x1b[36m",
        .gray => "\x1b[90m",
        .white => "\x1b[37m",
        .bg_red => "\x1b[41m",
        .bg_yellow => "\x1b[43m",
        .bg_magenta => "\x1b[45m",
    };
}

/// 以指定颜色打印格式化文本到标准输出
pub fn printColored(io: std.Io, c: Color, comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    var fw = std.Io.File.stdout().writer(io, &buf);
    fw.interface.writeAll(colorCode(c)) catch {};
    fw.interface.print(fmt, args) catch {};
    fw.interface.writeAll("\n") catch {};
    fw.interface.writeAll(colorCode(.reset)) catch {};
    fw.flush() catch {};
}

/// 清除当前终端行（用于进度条原地刷新）
pub fn clearLine(io: std.Io) void {
    var buf: [16]u8 = undefined;
    var fw = std.Io.File.stdout().writer(io, &buf);
    fw.interface.writeAll("\x1b[2K\r") catch {};
    fw.flush() catch {};
}

/// 以红色输出错误信息到标准错误流
/// 格式: ERROR: <message>
pub fn logError(io: std.Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    var fw = std.Io.File.stderr().writer(io, &buf);
    fw.interface.writeAll(colorCode(.red)) catch {};
    fw.interface.print("ERROR: ", .{}) catch {};
    fw.interface.print(fmt, args) catch {};
    fw.interface.writeAll("\n") catch {};
    fw.interface.writeAll(colorCode(.reset)) catch {};
    fw.flush() catch {};
}

/// 输出普通信息到标准输出（带换行）
pub fn logInfo(io: std.Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    var fw = std.Io.File.stdout().writer(io, &buf);
    fw.interface.print(fmt, args) catch {};
    fw.interface.writeAll("\n") catch {};
    fw.flush() catch {};
}
