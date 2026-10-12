//! What this release of GraniteOS is, as the shell's `about`, the desktop's About window, and Settings tell it.

pub const name = "GraniteOS 3";
pub const tagline = "A practical, everyday operating system written in Zig.";
pub const edition = "Alpha";

pub const features = [_][]const u8{

    "x86_64 UEFI boot",
    "Preemptive multicore scheduling",
    "Isolated processes, kernel-enforced permissions",
    "Supervised services with crash recovery",
    "GPU-accelerated graphical desktop",
    "Serial and graphical OBSIDIAN shell",
    "SATA storage and persistent files",
    "Accounts, private homes, and file permissions",
    "USB keyboard and mouse",
    "Installation beside an existing OS",

};
