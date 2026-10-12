pub const Entry = struct {

    id: u64 = 0,
    retries: u8 = 0,
    due: u64 = 0,
    offline: bool = false,
    available: bool = false,

    pub fn failed(self: *Entry, now: u64) void {

        self.id = 0;
        self.available = false;

        if (self.retries == 3) {

            self.offline = true;
            return;

        }

        self.due = now +| (@as(u64, 10) << @intCast(self.retries));
        self.retries += 1;

    }

    pub fn ready(self: Entry, now: u64) bool {

        return self.id == 0 and !self.offline and now >= self.due;

    }

};
