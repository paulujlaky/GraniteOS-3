const std = @import("std");

const abi = @import("abi");
const Request = abi.Request;

extern fn invoke(request: *Request) callconv(.c) void;
extern fn burn(value: u64) callconv(.c) u64;

pub const panic = std.debug.FullPanic(fatal);

fn call(number: abi.Call, first: u64, second: u64, third: u64) Request {

    var request = Request{

        .number = @intFromEnum(number),
        .first = first,
        .second = second,
        .third = third,

    };

    invoke(&request);

    return request;

}

fn check(condition: bool) void {

    if (!condition) finish(99);

}

fn finish(status: u64) noreturn {

    _ = call(.exit, status, 0, 0);

    while (true) asm volatile ("ud2"); // Fault if the exit syscall returns.

}

fn fatal(_: []const u8, _: ?usize) noreturn {

    finish(98);

}

pub export fn app_main(role: usize, peer: usize, environment: *const abi.Environment) callconv(.c) noreturn {

    switch (role) {

        0 => {

            const message = call(.receive, 0, 0, 0);

            check(message.number == 0 and message.second == 41);
            check(call(.send, message.first, 42, 0).number == 0);

        },
        1 => {

            check(call(.send, peer, 41, 0).number == 0);

            const reply = call(.receive, 0, 0, 0);

            check(reply.number == 0 and reply.first == peer and reply.second == 42);

        },
        2 => {

            const id = call(.identity, 0, 0, 0).first;

            check(burn(id) == id);

        },
        3 => {

            const forbidden: *volatile u64 = @ptrFromInt(0x100000);

            _ = forbidden.*;
            finish(97);

        },
        4 => {

            asm volatile ("outb %%al, %%dx" // Test that direct port access faults.
                :
                : [value] "{al}" (@as(u8, 0)),
                  [port] "{dx}" (@as(u16, 0x80)),
            );
            finish(96);

        },
        5 => {

            var code = [_]u8{

                0xc3

            };

            const execute: *const fn () callconv(.c) void = @ptrCast(&code);

            execute();
            finish(95);

        },
        6 => {

            check(call(.port, 0x80, 0, 0).number == 0);
            check(call(.port, 0x81, 0, 0).number == 1);
            check(call(.port, 0x3f8, 1, 0).number == 1);
            check(call(.map, 0xfee00000, 0, 0).number == 1);
            check(call(.reboot, 0, 0, 0).number == 1);
            check(call(.send, 1, 123, 0).number == 1);
            check(call(.write, 0x100000, 8, 0).number != 0);
            check(call(.write, 0xfffffffffffffff0, 32, 0).number != 0);
            check(call(@enumFromInt(1000), 0, 0, 0).number == 2);

            const allocation = call(.allocate, 0, 0, 0);

            check(allocation.number == 0);

            const page: *[4096]u8 = @ptrFromInt(allocation.first);

            for (page) |byte| check(byte == 0);

            @memset(page, 0xa5);
            check(call(.write, allocation.first + 4090, 16, 0).number != 0);

            const adjacent = call(.allocate, 0, 0, 0);

            check(adjacent.number == 0 and adjacent.first == allocation.first + 4096);
            @memcpy(page[4090..], "cross ");
            @memcpy(@as([*]u8, @ptrFromInt(adjacent.first))[0..5], "page\n");
            check(call(.write, allocation.first + 4090, 11, 0).number == 0);
            check(call(.write, adjacent.first + 4090, 16, 0).number != 0);
            check(call(.release, adjacent.first, 0, 0).number == 0);
            check(call(.release, allocation.first, 0, 0).number == 0);
            check(call(.release, allocation.first, 0, 0).number != 0);

            const reused = call(.allocate, 0, 0, 0);

            check(reused.number == 0 and reused.first == allocation.first);
            for (@as(*[4096]u8, @ptrFromInt(reused.first))) |byte| check(byte == 0);

            check(call(.release, reused.first, 0, 0).number == 0);

            if (peer != 0) {

                const mapped = call(.map, peer, 0, 0);

                check(mapped.number == 0);
                _ = @as(*volatile u8, @ptrFromInt(mapped.first)).*;
                check(call(.release, mapped.first, 0, 0).number == 0);

            }

        },
        7 => {

            @as(*volatile u8, @ptrFromInt(0x8000000000)).* = 0;
            finish(93);

        },
        8 => {

            // Below the stack and the environment page beneath it.
            _ = @as(*volatile u8, @ptrFromInt(0xffffff0000 - 4096)).*;
            finish(92);

        },
        9 => {

            const length: *volatile u64 = @constCast(&environment.length);
            length.* = 0;
            finish(91);

        },
        else => finish(94),

    }

    finish(0);

}
