//! 终端 UI 与日志模块
//! 提供日志级别控制、ANSI 颜色输出、进度显示等功能。

const std = @import("std");

/// 日志级别
pub const LogLevel = enum(u8) {
    err = 0,
    warn = 1,
    info = 2,
    debug = 3,
};

/// 全局日志级别（运行时可通过 setLogLevel 修改）
var current_log_level: LogLevel = .info;

/// 设置全局日志级别
pub fn setLogLevel(level: LogLevel) void {
    current_log_level = level;
}

/// 获取当前日志级别
pub fn logLevel() LogLevel {
    return current_log_level;
}

/// 支持的终端颜色
pub const Color = enum {
    reset,
    red,
    green,
    yellow,
    cyan,
    gray,
    white,
    bg_red,
    bg_yellow,
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

/// DEBUG 级别日志（灰色前缀，仅当日志级别 >= debug 时输出）
pub fn logDebug(io: std.Io, comptime fmt: []const u8, args: anytype) void {
    if (@intFromEnum(current_log_level) < @intFromEnum(LogLevel.debug)) return;
    var buf: [4096]u8 = undefined;
    var fw = std.Io.File.stderr().writer(io, &buf);
    fw.interface.writeAll(colorCode(.gray)) catch {};
    fw.interface.print("[D] " ++ fmt, args) catch {};
    fw.interface.writeAll("\n") catch {};
    fw.interface.writeAll(colorCode(.reset)) catch {};
    fw.flush() catch {};
}

/// WARN 级别日志（黄色前缀，仅当日志级别 >= warn 时输出）
pub fn logWarn(io: std.Io, comptime fmt: []const u8, args: anytype) void {
    if (@intFromEnum(current_log_level) < @intFromEnum(LogLevel.warn)) return;
    var buf: [4096]u8 = undefined;
    var fw = std.Io.File.stderr().writer(io, &buf);
    fw.interface.writeAll(colorCode(.yellow)) catch {};
    fw.interface.print("[W] " ++ fmt, args) catch {};
    fw.interface.writeAll("\n") catch {};
    fw.interface.writeAll(colorCode(.reset)) catch {};
    fw.flush() catch {};
}

/// ERROR 级别日志（红色前缀，始终输出）
pub fn logError(io: std.Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    var fw = std.Io.File.stderr().writer(io, &buf);
    fw.interface.writeAll(colorCode(.red)) catch {};
    fw.interface.print("[E] " ++ fmt, args) catch {};
    fw.interface.writeAll("\n") catch {};
    fw.interface.writeAll(colorCode(.reset)) catch {};
    fw.flush() catch {};
}

/// INFO 级别日志（标准输出，无颜色前缀，仅当日志级别 >= info 时输出）
pub fn logInfo(io: std.Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    var fw = std.Io.File.stdout().writer(io, &buf);
    fw.interface.print(fmt, args) catch {};
    fw.interface.writeAll("\n") catch {};
    fw.flush() catch {};
}
