const abi = @import("abi.zig");

pub const PolicyError = error{ Denied, Invalid };

pub const application = Policy{

    .layer = .application,
    .length = 3,
    .permissions = [_]abi.Permission{

        .ipc, .memory, .time

    } ++ [_]abi.Permission{

        .ipc

    } ** (abi.permission_count - 3),

};

pub const Policy = struct {

    layer: abi.Layer = .application,
    length: usize = 0,

    permissions: [abi.permission_count]abi.Permission = [_]abi.Permission{

        .ipc

    } ** abi.permission_count,

    pub fn init(layer: abi.Layer, permissions: []const abi.Permission) PolicyError!Policy {

        if (permissions.len > abi.permission_count) return error.Invalid;

        var result = Policy{

            .layer = layer

        };

        for (permissions) |permission| {

            if (layer == .application and privileged(permission)) return error.Denied;
            if (result.permits(permission)) return error.Invalid;

            result.permissions[result.length] = permission;
            result.length += 1;

        }

        return result;

    }

    pub fn permits(self: *const Policy, permission: abi.Permission) bool {

        for (self.permissions[0..self.length]) |entry| {

            if (entry == permission) return true;

        }

        return false;

    }

};

fn privileged(permission: abi.Permission) bool {

    return switch (permission) {

        .ports, .mmio, .power, .management, .dma, .accounts, .firmware => true,
        else => false,

    };

}
