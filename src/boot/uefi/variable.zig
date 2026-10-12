const std = @import("std");

const uefi = std.os.uefi;

pub const VariableError = error{ NoDevice, Invalid };

/// Reads or writes a global firmware variable; runtime services stay in physical mode, so `table` is identity-mapped.
pub fn access(table: u64, name: [*:0]const u16, data: []u8, write: bool) VariableError!usize {

    if (table == 0) return error.NoDevice;

    const services: *const uefi.tables.RuntimeServices = @ptrFromInt(table);

    const attributes = uefi.tables.RuntimeServices.VariableAttributes{

        .non_volatile = true,
        .bootservice_access = true,
        .runtime_access = true,

    };

    var size = data.len;

    const status = if (write) services._setVariable(name, &uefi.tables.global_variable, attributes, data.len, data.ptr) else services._getVariable(name, &uefi.tables.global_variable, null, &size, data.ptr);

    return switch (status) {

        .success => size,
        .not_found => error.NoDevice,
        else => error.Invalid,

    };

}
