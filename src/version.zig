const build_options = @import("build_options");

pub const string: []const u8 = build_options.version;
pub const commit: []const u8 = build_options.git_commit;
pub const branch: []const u8 = build_options.git_branch;
pub const build_timestamp: []const u8 = build_options.build_timestamp;
