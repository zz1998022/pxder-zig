const std = @import("std");
const cli_args = @import("args.zig");

pub fn parseArgsList(args: []const []const u8) !cli_args.CliArgs {
    var result = cli_args.CliArgs{};
    var i: usize = 0;

    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--login")) {
            if (i + 1 < args.len and args[i + 1][0] != '-') {
                i += 1;
                result.token = args[i];
                result.action = .login_token;
            } else {
                result.action = .login;
            }
        } else if (std.mem.eql(u8, arg, "--logout")) {
            result.action = .logout;
        } else if (std.mem.eql(u8, arg, "--setting")) {
            result.action = .setting;
        } else if (std.mem.eql(u8, arg, "-u") or std.mem.eql(u8, arg, "--uid")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            result.uids = args[i];
            result.action = .download_uid;
        } else if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--pid")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            result.pids = args[i];
            result.action = .download_pid;
        } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--follow")) {
            result.action = .download_follow;
        } else if (std.mem.eql(u8, arg, "-F") or std.mem.eql(u8, arg, "--follow-private")) {
            result.action = .download_follow_private;
        } else if (std.mem.eql(u8, arg, "-b") or std.mem.eql(u8, arg, "--bookmark")) {
            result.action = .download_bookmark;
        } else if (std.mem.eql(u8, arg, "-B") or std.mem.eql(u8, arg, "--bookmark-private")) {
            result.action = .download_bookmark_private;
        } else if (std.mem.eql(u8, arg, "-U") or std.mem.eql(u8, arg, "--update")) {
            result.action = .download_update;
        } else if (std.mem.eql(u8, arg, "--force")) {
            result.force = true;
        } else if (std.mem.eql(u8, arg, "-M") or std.mem.eql(u8, arg, "--no-ugoira-meta")) {
            result.no_ugoira_meta = true;
        } else if (std.mem.eql(u8, arg, "-O") or std.mem.eql(u8, arg, "--output-dir")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            result.output_dir = args[i];
        } else if (std.mem.eql(u8, arg, "--debug")) {
            result.debug = true;
        } else if (std.mem.eql(u8, arg, "--no-protocol")) {
            result.no_protocol = true;
        } else if (std.mem.eql(u8, arg, "--output-config-dir")) {
            result.action = .show_config_dir;
        } else if (std.mem.eql(u8, arg, "--export-token")) {
            result.action = .export_token;
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--version")) {
            result.action = .show_version;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            result.action = .show_help;
        } else {
            return error.UnknownArgument;
        }
    }

    return result;
}
