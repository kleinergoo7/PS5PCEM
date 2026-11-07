// Experimental PS4 compatibility mode scaffold.
pub const Mode = enum { disabled, enabled };

pub fn isPs4Title(_: []const u8) bool {
    return false;
}
