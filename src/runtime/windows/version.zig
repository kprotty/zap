const std = @import("std");
const windows = std.os.windows;

const VersionState = enum(usize) {
    uninit,
    newer,
    older,
};

pub fn isWindowsVersionOrHigher(
    comptime version: std.Target.Os.WindowsVersion,
) bool {
    const Cached = struct {
        var version_state: VersionState = .uninit;

        fn get() bool {
            const state = @atomicLoad(VersionState, &version_state, .Monotonic);
            if (state == .uninit)
                return getSlow();
            return state == .newer;
        }

        fn getSlow() bool {
            @setCold(true);

            const is_version_or_higher = switch (version) {
                .win7 => IsWindows7OrGreater() != windows.FALSE,
                .vista => IsWindowsVistaOrGreater() != windows.FALSE,
                else => @compileError("TODO: add more windows version checks"),
            };

            const state: VersionState = if (is_version_or_higher) .newer else .older;
            @atomicStore(VersionState, &version_state, state, .Monotonic);
            return is_version_or_higher;
        }
    };

    return Cached.get();
}

const VERSIONHELPERAPI = windows.BOOL;

extern "kernel32" fn IsWindows7OrGreater() callconv(.C) VERSIONHELPERAPI;
extern "kernel32" fn IsWindowsVistaOrGreater() callconv(.C) VERSIONHELPERAPI;
