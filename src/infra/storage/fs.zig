const std = @import("std");

/// 检查文件是否存在
pub fn fileExists(io: std.Io, path: []const u8) bool {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    file.close(io);
    return true;
}

/// 将字节数据写入文件（覆盖已存在的文件）
pub fn writeFile(io: std.Io, path: []const u8, data: []const u8) !void {
    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var buf: [8192]u8 = undefined;
    var writer = file.writer(io, &buf);
    try writer.interface.writeAll(data);
    try writer.flush();
}

/// 获取文件大小
pub fn getFileSize(io: std.Io, path: []const u8) !u64 {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var reader = file.reader(io, &buf);
    return reader.getSize();
}

/// 移动文件（先尝试 rename，失败则复制+删除）
pub fn moveFile(io: std.Io, src: []const u8, dst: []const u8) !void {
    // 先尝试原子 rename
    std.Io.Dir.rename(std.Io.Dir.cwd(), src, std.Io.Dir.cwd(), dst, io) catch {
        // rename 失败（可能跨设备），改用复制+删除
        const src_file = std.Io.Dir.cwd().openFile(io, src, .{}) catch |err| return err;
        defer src_file.close(io);

        var read_buf: [8192]u8 = undefined;
        var src_reader = src_file.reader(io, &read_buf);

        const dst_file = std.Io.Dir.cwd().createFile(io, dst, .{}) catch |err| return err;
        errdefer deleteFile(io, dst);
        defer dst_file.close(io);

        var write_buf: [8192]u8 = undefined;
        var dst_writer = dst_file.writer(io, &write_buf);

        // 流式复制
        const stat = src_reader.getSize() catch |err| return err;
        var remaining: u64 = @intCast(stat);
        while (remaining > 0) {
            const to_read: usize = @min(remaining, read_buf.len);
            const chunk = src_reader.interface.take(to_read) catch |err| return err;
            dst_writer.interface.writeAll(chunk) catch |err| return err;
            remaining -= to_read;
        }
        try dst_writer.flush();

        // 删除源文件
        deleteFile(io, src);
    };
}

/// 删除文件
pub fn deleteFile(io: std.Io, path: []const u8) void {
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
}

/// 重命名目录
pub fn renameDir(io: std.Io, old_path: []const u8, new_path: []const u8) !void {
    std.Io.Dir.rename(std.Io.Dir.cwd(), old_path, std.Io.Dir.cwd(), new_path, io) catch |err| return err;
}

/// 清理目录中的所有文件和子目录
pub fn cleanDir(allocator: std.mem.Allocator, io: std.Io, dir_path: []const u8) void {
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        const entry_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, entry.name }) catch continue;
        defer allocator.free(entry_path);

        switch (entry.kind) {
            .file => {
                deleteFile(io, entry_path);
            },
            .directory => {
                // 递归清理子目录
                cleanDir(allocator, io, entry_path);
                std.Io.Dir.cwd().deleteDir(io, entry_path) catch {};
            },
            else => {},
        }
    }
}
