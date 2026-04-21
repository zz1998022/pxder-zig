const std = @import("std");
const illust = @import("core/illust.zig");
const pixiv_api = @import("pixiv_api.zig");

const USER_DETAIL_ITERS: usize = 20_000;
const FOLLOWING_ITERS: usize = 4_000;
const ILLUST_PAGE_ITERS: usize = 1_200;
const UGOIRA_META_ITERS: usize = 20_000;

const BenchResult = struct {
    name: []const u8,
    iterations: usize,
    elapsed_ns: u64,
    checksum: u64,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    const user_detail_payload = try buildUserDetailPayload(allocator);
    defer allocator.free(user_detail_payload);

    const following_payload = try buildFollowingPayload(allocator, 30);
    defer allocator.free(following_payload);

    const illust_page_payload = try buildIllustPagePayload(allocator, 30);
    defer allocator.free(illust_page_payload);

    const ugoira_meta_payload = try buildUgoiraMetadataPayload(allocator, 12);
    defer allocator.free(ugoira_meta_payload);

    const results = [_]BenchResult{
        try benchDynamicUserDetail(allocator, io, user_detail_payload, USER_DETAIL_ITERS),
        try benchTypedUserDetail(allocator, io, user_detail_payload, USER_DETAIL_ITERS),
        try benchDynamicFollowing(allocator, io, following_payload, FOLLOWING_ITERS),
        try benchTypedFollowing(allocator, io, following_payload, FOLLOWING_ITERS),
        try benchDynamicIllustPage(allocator, io, illust_page_payload, ILLUST_PAGE_ITERS),
        try benchTypedIllustPage(allocator, io, illust_page_payload, ILLUST_PAGE_ITERS),
        try benchDynamicUgoiraMeta(allocator, io, ugoira_meta_payload, UGOIRA_META_ITERS),
        try benchTypedUgoiraMeta(allocator, io, ugoira_meta_payload, UGOIRA_META_ITERS),
    };

    std.debug.print("pxder-zig benchmark (synthetic parse hotspots)\n", .{});
    std.debug.print("Tip: use `zig build bench -Doptimize=ReleaseFast` for representative numbers.\n\n", .{});

    for (results) |result| {
        printResult(result);
    }

    printSpeedup(results[0], results[1]);
    printSpeedup(results[2], results[3]);
    printSpeedup(results[4], results[5]);
    printSpeedup(results[6], results[7]);
}

fn printResult(result: BenchResult) void {
    const total_ms = nsToMs(result.elapsed_ns);
    const avg_us = nsToUs(result.elapsed_ns) / @as(f64, @floatFromInt(result.iterations));
    const ops_per_sec = @as(f64, @floatFromInt(result.iterations)) / (total_ms / 1000.0);

    std.debug.print(
        "{s}  total={d:.3} ms  avg={d:.3} us  ops/s={d:.1}  checksum={d}\n",
        .{ result.name, total_ms, avg_us, ops_per_sec, result.checksum },
    );
}

fn printSpeedup(dynamic: BenchResult, typed: BenchResult) void {
    const speedup = @as(f64, @floatFromInt(dynamic.elapsed_ns)) / @as(f64, @floatFromInt(typed.elapsed_ns));
    std.debug.print("speedup  {s} -> {s}: {d:.2}x\n", .{ dynamic.name, typed.name, speedup });
}

fn benchDynamicUserDetail(allocator: std.mem.Allocator, io: std.Io, payload: []const u8, iterations: usize) !BenchResult {
    var checksum: u64 = 0;
    const start = std.Io.Clock.Timestamp.now(io, .awake);
    for (0..iterations) |_| {
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
        const user = getFieldObject(parsed.value, "user") orelse return error.InvalidPayload;
        const name = user.get("name") orelse return error.InvalidPayload;
        if (name != .string) return error.InvalidPayload;
        checksum +%= name.string.len;
        parsed.deinit();
    }
    std.mem.doNotOptimizeAway(checksum);
    return .{ .name = "dynamic user_detail", .iterations = iterations, .elapsed_ns = elapsedNs(start, io), .checksum = checksum };
}

fn benchTypedUserDetail(allocator: std.mem.Allocator, io: std.Io, payload: []const u8, iterations: usize) !BenchResult {
    var checksum: u64 = 0;
    const start = std.Io.Clock.Timestamp.now(io, .awake);
    for (0..iterations) |_| {
        const parsed = try std.json.parseFromSlice(pixiv_api.UserDetailLite, allocator, payload, .{
            .ignore_unknown_fields = true,
        });
        checksum +%= parsed.value.user.name.len;
        parsed.deinit();
    }
    std.mem.doNotOptimizeAway(checksum);
    return .{ .name = "typed user_detail", .iterations = iterations, .elapsed_ns = elapsedNs(start, io), .checksum = checksum };
}

fn benchDynamicFollowing(allocator: std.mem.Allocator, io: std.Io, payload: []const u8, iterations: usize) !BenchResult {
    var checksum: u64 = 0;
    const start = std.Io.Clock.Timestamp.now(io, .awake);
    for (0..iterations) |_| {
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});

        if (getFieldString(parsed.value, "next_url")) |next_url| checksum +%= next_url.len;
        const previews = getFieldArray(parsed.value, "user_previews") orelse return error.InvalidPayload;
        for (previews.items) |item| {
            if (item != .object) return error.InvalidPayload;
            const user = item.object.get("user") orelse return error.InvalidPayload;
            if (user != .object) return error.InvalidPayload;
            const id = user.object.get("id") orelse return error.InvalidPayload;
            const name = user.object.get("name") orelse return error.InvalidPayload;
            if (id != .integer or name != .string) return error.InvalidPayload;
            checksum +%= @as(u64, @intCast(id.integer));
            checksum +%= name.string.len;
        }
        parsed.deinit();
    }
    std.mem.doNotOptimizeAway(checksum);
    return .{ .name = "dynamic following", .iterations = iterations, .elapsed_ns = elapsedNs(start, io), .checksum = checksum };
}

fn benchTypedFollowing(allocator: std.mem.Allocator, io: std.Io, payload: []const u8, iterations: usize) !BenchResult {
    var checksum: u64 = 0;
    const start = std.Io.Clock.Timestamp.now(io, .awake);
    for (0..iterations) |_| {
        const parsed = try std.json.parseFromSlice(pixiv_api.UserFollowingLite, allocator, payload, .{
            .ignore_unknown_fields = true,
        });

        if (parsed.value.next_url) |next_url| checksum +%= next_url.len;
        for (parsed.value.user_previews) |preview| {
            checksum +%= preview.user.id;
            checksum +%= preview.user.name.len;
        }
        parsed.deinit();
    }
    std.mem.doNotOptimizeAway(checksum);
    return .{ .name = "typed following", .iterations = iterations, .elapsed_ns = elapsedNs(start, io), .checksum = checksum };
}

fn benchDynamicIllustPage(allocator: std.mem.Allocator, io: std.Io, payload: []const u8, iterations: usize) !BenchResult {
    var checksum: u64 = 0;
    const start = std.Io.Clock.Timestamp.now(io, .awake);
    for (0..iterations) |_| {
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});

        if (getFieldString(parsed.value, "next_url")) |next_url| checksum +%= next_url.len;
        const illusts_array = getFieldArray(parsed.value, "illusts") orelse return error.InvalidPayload;
        for (illusts_array.items) |item| {
            const tasks = try illust.parseIllusts(allocator, item, null);
            checksum +%= accumulateTasks(tasks);
            illust.deinitIllusts(allocator, tasks);
        }
        parsed.deinit();
    }
    std.mem.doNotOptimizeAway(checksum);
    return .{ .name = "dynamic illust_page", .iterations = iterations, .elapsed_ns = elapsedNs(start, io), .checksum = checksum };
}

fn benchTypedIllustPage(allocator: std.mem.Allocator, io: std.Io, payload: []const u8, iterations: usize) !BenchResult {
    var checksum: u64 = 0;
    const start = std.Io.Clock.Timestamp.now(io, .awake);
    for (0..iterations) |_| {
        const parsed = try std.json.parseFromSlice(pixiv_api.UserIllustsLite, allocator, payload, .{
            .ignore_unknown_fields = true,
        });

        if (parsed.value.next_url) |next_url| checksum +%= next_url.len;
        for (parsed.value.illusts) |item| {
            const tasks = try illust.parseIllustLite(allocator, item, null);
            checksum +%= accumulateTasks(tasks);
            illust.deinitIllusts(allocator, tasks);
        }
        parsed.deinit();
    }
    std.mem.doNotOptimizeAway(checksum);
    return .{ .name = "typed illust_page", .iterations = iterations, .elapsed_ns = elapsedNs(start, io), .checksum = checksum };
}

fn benchDynamicUgoiraMeta(allocator: std.mem.Allocator, io: std.Io, payload: []const u8, iterations: usize) !BenchResult {
    var checksum: u64 = 0;
    const start = std.Io.Clock.Timestamp.now(io, .awake);
    for (0..iterations) |_| {
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});

        const meta = getFieldObject(parsed.value, "ugoira_metadata") orelse return error.InvalidPayload;
        const frames_val = meta.get("frames") orelse return error.InvalidPayload;
        if (frames_val != .array) return error.InvalidPayload;
        for (frames_val.array.items) |frame| {
            const delay = getFieldInt(frame, "delay") orelse return error.InvalidPayload;
            checksum +%= @as(u64, @intCast(delay));
        }
        parsed.deinit();
    }
    std.mem.doNotOptimizeAway(checksum);
    return .{ .name = "dynamic ugoira_meta", .iterations = iterations, .elapsed_ns = elapsedNs(start, io), .checksum = checksum };
}

fn benchTypedUgoiraMeta(allocator: std.mem.Allocator, io: std.Io, payload: []const u8, iterations: usize) !BenchResult {
    var checksum: u64 = 0;
    const start = std.Io.Clock.Timestamp.now(io, .awake);
    for (0..iterations) |_| {
        const parsed = try std.json.parseFromSlice(pixiv_api.UgoiraMetadataLite, allocator, payload, .{
            .ignore_unknown_fields = true,
        });

        for (parsed.value.ugoira_metadata.frames) |frame| {
            checksum +%= frame.delay;
        }
        parsed.deinit();
    }
    std.mem.doNotOptimizeAway(checksum);
    return .{ .name = "typed ugoira_meta", .iterations = iterations, .elapsed_ns = elapsedNs(start, io), .checksum = checksum };
}

fn accumulateTasks(tasks: []const illust.Illust) u64 {
    var checksum: u64 = 0;
    for (tasks) |task| {
        checksum +%= task.id;
        checksum +%= task.url.len;
        checksum +%= task.file.len;
        checksum +%= @intFromEnum(task.illust_type);
    }
    return checksum;
}

fn buildUserDetailPayload(allocator: std.mem.Allocator) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"user\":{{\"id\":12345678,\"name\":\"Benchmark Artist\",\"account\":\"bench_user\"}},\"profile\":{{\"comment\":\"synthetic\"}}}}",
        .{},
    );
}

fn buildFollowingPayload(allocator: std.mem.Allocator, count: usize) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"next_url\":\"https://app-api.pixiv.net/v1/user/following?page=2\",\"user_previews\":[");
    for (0..count) |i| {
        if (i > 0) try buf.append(allocator, ',');
        const entry = try std.fmt.allocPrint(
            allocator,
            "{{\"user\":{{\"id\":{d},\"name\":\"Artist {d}\"}},\"illusts\":[]}}",
            .{ 10_000 + i, i },
        );
        defer allocator.free(entry);
        try buf.appendSlice(allocator, entry);
    }
    try buf.appendSlice(allocator, "]}");
    return buf.toOwnedSlice(allocator);
}

fn buildIllustPagePayload(allocator: std.mem.Allocator, count: usize) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"next_url\":\"https://app-api.pixiv.net/v1/user/illusts?page=2\",\"illusts\":[");
    for (0..count) |i| {
        if (i > 0) try buf.append(allocator, ',');
        const illust_id = 20_000 + i;
        const item = switch (i % 3) {
            0 => try std.fmt.allocPrint(
                allocator,
                "{{\"id\":{d},\"title\":\"Single {d}\",\"type\":\"illust\",\"meta_single_page\":{{\"original_image_url\":\"https://i.pximg.net/img-original/img/2024/01/01/00/00/00/{d}_p0.jpg\"}},\"meta_pages\":[]}}",
                .{ illust_id, i, illust_id },
            ),
            1 => try std.fmt.allocPrint(
                allocator,
                "{{\"id\":{d},\"title\":\"Multi {d}\",\"type\":\"manga\",\"meta_single_page\":{{}},\"meta_pages\":[{{\"image_urls\":{{\"original\":\"https://i.pximg.net/img-original/img/2024/01/01/00/00/00/{d}_p0.png\"}}}},{{\"image_urls\":{{\"original\":\"https://i.pximg.net/img-original/img/2024/01/01/00/00/00/{d}_p1.png\"}}}},{{\"image_urls\":{{\"original\":\"https://i.pximg.net/img-original/img/2024/01/01/00/00/00/{d}_p2.png\"}}}}]}}",
                .{ illust_id, i, illust_id, illust_id, illust_id },
            ),
            else => try std.fmt.allocPrint(
                allocator,
                "{{\"id\":{d},\"title\":\"Ugoira {d}\",\"type\":\"ugoira\",\"meta_single_page\":{{\"original_image_url\":\"https://i.pximg.net/img-original/img/2024/01/01/00/00/00/{d}_ugoira0.jpg\"}},\"meta_pages\":[]}}",
                .{ illust_id, i, illust_id },
            ),
        };
        defer allocator.free(item);
        try buf.appendSlice(allocator, item);
    }
    try buf.appendSlice(allocator, "]}");
    return buf.toOwnedSlice(allocator);
}

fn buildUgoiraMetadataPayload(allocator: std.mem.Allocator, frame_count: usize) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"ugoira_metadata\":{\"frames\":[");
    for (0..frame_count) |i| {
        if (i > 0) try buf.append(allocator, ',');
        const frame = try std.fmt.allocPrint(allocator, "{{\"file\":\"{d}.jpg\",\"delay\":{d}}}", .{ i, 60 + (i % 3) * 20 });
        defer allocator.free(frame);
        try buf.appendSlice(allocator, frame);
    }
    try buf.appendSlice(allocator, "]}}");
    return buf.toOwnedSlice(allocator);
}

fn nsToMs(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1_000_000.0;
}

fn nsToUs(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1_000.0;
}

fn elapsedNs(start: std.Io.Clock.Timestamp, io: std.Io) u64 {
    return @intCast(start.untilNow(io).raw.toNanoseconds());
}

fn getFieldString(obj: std.json.Value, key: []const u8) ?[]const u8 {
    if (obj != .object) return null;
    const value = obj.object.get(key) orelse return null;
    if (value != .string) return null;
    return value.string;
}

fn getFieldInt(obj: std.json.Value, key: []const u8) ?i64 {
    if (obj != .object) return null;
    const value = obj.object.get(key) orelse return null;
    return switch (value) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        else => null,
    };
}

fn getFieldArray(obj: std.json.Value, key: []const u8) ?std.json.Array {
    if (obj != .object) return null;
    const value = obj.object.get(key) orelse return null;
    if (value != .array) return null;
    return value.array;
}

fn getFieldObject(obj: std.json.Value, key: []const u8) ?std.json.ObjectMap {
    if (obj != .object) return null;
    const value = obj.object.get(key) orelse return null;
    if (value != .object) return null;
    return value.object;
}
