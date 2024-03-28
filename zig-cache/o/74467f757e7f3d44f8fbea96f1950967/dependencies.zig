pub const packages = struct {
    pub const @"1220acfc53954f699415c6942422571670544a5236866fa7b6e069e2b1b2ba86ae9c" = struct {
        pub const build_root = "/Users/srijan-paul/.cache/zig/p/1220acfc53954f699415c6942422571670544a5236866fa7b6e069e2b1b2ba86ae9c";
        pub const build_zig = @import("1220acfc53954f699415c6942422571670544a5236866fa7b6e069e2b1b2ba86ae9c");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
            .{ "macos_sdk", "1220bc2612b57b0cfaaecbcac38e3144e5a9362ff668d71eb8334e895047bdbb7148" },
        };
    };
    pub const @"1220bc2612b57b0cfaaecbcac38e3144e5a9362ff668d71eb8334e895047bdbb7148" = struct {
        pub const build_root = "/Users/srijan-paul/.cache/zig/p/1220bc2612b57b0cfaaecbcac38e3144e5a9362ff668d71eb8334e895047bdbb7148";
        pub const build_zig = @import("1220bc2612b57b0cfaaecbcac38e3144e5a9362ff668d71eb8334e895047bdbb7148");
        pub const deps: []const struct { []const u8, []const u8 } = &.{};
    };
};

pub const root_deps: []const struct { []const u8, []const u8 } = &.{
    .{ "zig-objc", "1220acfc53954f699415c6942422571670544a5236866fa7b6e069e2b1b2ba86ae9c" },
};
