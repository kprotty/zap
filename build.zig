// Copyright (c) 2020 kprotty
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// 	http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    const entry_point = "./src/zap.zig";
    const entry_point_test = "./tests/zap.zig";

    const Options = struct {
        mode: std.builtin.Mode,
        target: std.zig.CrossTarget,
        libc: bool,
        single_threaded: bool,

        fn applyTo(self: @This(), step: anytype) void {
            if (self.libc)
                step.linkLibC();
            step.single_threaded = self.single_threaded;
            step.setBuildMode(self.mode);
            step.setTarget(self.target);
        }
    };

    const options = Options{
        .mode = b.standardReleaseOptions(),
        .target = b.standardTargetOptions(.{}),
        .libc = b.option(bool, "c", "Link libc") orelse false,
        .single_threaded = b.option(bool, "single-threaded", "Assume program is single-threaded") orelse false,
    };

    // step to format code
    {
        const format_step = b.addFmt(&[_][]const u8{
            "src",
            "tests",
            "build.zig",
        });

        const step = b.step("fmt", "Format all code using zig fmt");
        step.dependOn(&format_step.step);
    }

    // step to run tests
    {
        const test_step = b.addTest(entry_point_test);
        options.applyTo(test_step);
        test_step.addPackagePath("zap", entry_point);

        const step = b.step("test", "Run all tests for zap");
        step.dependOn(&test_step.step);
    }

    // step to build docs
    {
        const docs_step = b.addSystemCommand(&[_][]const u8{
            b.zig_exe,
            "test",
            entry_point_test,
            "-femit-docs",
            "-fno-emit-bin",
            "--output-dir",
            "--pkg-begin",
            "zap",
            entry_point,
            "--pkg-end",
            ".",
        });

        const step = b.step("docs", "Build zig docs for zap");
        step.dependOn(&docs_step.step);
    }
}
