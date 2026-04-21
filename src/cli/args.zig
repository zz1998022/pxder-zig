const std = @import("std");

pub const version = "0.1.0";

pub const CliAction = enum {
    login,
    login_token,
    logout,
    setting,
    download_uid,
    download_pid,
    download_follow,
    download_follow_private,
    download_bookmark,
    download_bookmark_private,
    download_update,
    show_config_dir,
    show_version,
    show_help,
    export_token,
};

pub const CliArgs = struct {
    action: ?CliAction = null,
    token: ?[]const u8 = null,
    pids: ?[]const u8 = null,
    uids: ?[]const u8 = null,
    force: bool = false,
    no_ugoira_meta: bool = false,
    output_dir: ?[]const u8 = null,
    debug: bool = false,
    no_protocol: bool = false,
};
