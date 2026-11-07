// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 kleinergoo7

//! Submission ledger: EOP labels, completion events, flip ordering.
//!
//! The shared completion path keys off pipe+queue. PS4 titles use legacy
//! queue identities and expect ordered CPU flips to publish completion labels
//! only after the flip lands. This ledger tracks requested labels, submitted
//! command-buffer copies (retained until their fence fires, for validation
//! and RenderDoc-style capture), and flip-ordered publication.

const std = @import("std");

/// One in-flight submission.
pub const Submission = struct {
    id: u64,
    pipe: u8,
    queue: u8,
    label_addr: u64, // guest address of the completion label, 0 = none
    label_value: u64, // value written on completion
    completed: bool = false,
    flip_ordered: bool = false, // publish only after ordered CPU flip
};

/// Flip-offset publication: labels for flip-ordered submissions are held
/// until `publishFlipsUpTo(flip)` passes their flip index.
pub const Ledger = struct {
    next_id: u64 = 1,
    submissions: [64]Submission = undefined,
    count: usize = 0,
    completed_flip: u64 = 0,

    pub fn submit(self: *Ledger, pipe: u8, queue: u8, label_addr: u64, label_value: u64, flip_ordered: bool) u64 {
        const id = self.next_id;
        self.next_id += 1;
        if (self.count < self.submissions.len) {
            self.submissions[self.count] = .{
                .id = id,
                .pipe = pipe,
                .queue = queue,
                .label_addr = label_addr,
                .label_value = label_value,
                .flip_ordered = flip_ordered,
            };
            self.count += 1;
        }
        return id;
    }

    /// Mark a submission's GPU work finished. Flip-ordered labels stay held.
    pub fn completeGpu(self: *Ledger, id: u64) void {
        for (self.submissions[0..self.count]) |*s| {
            if (s.id == id) {
                if (!s.flip_ordered) s.completed = true;
                return;
            }
        }
    }

    /// Publish flip-ordered labels up to `flip`, retiring completed entries.
    /// Returns labels to write: pairs of (addr, value) packed into `out`.
    pub fn publishFlipsUpTo(self: *Ledger, flip: u64, out: [][2]u64) usize {
        self.completed_flip = @max(self.completed_flip, flip);
        var n: usize = 0;
        var kept: usize = 0;
        for (self.submissions[0..self.count]) |*s| {
            if (s.flip_ordered and !s.completed) {
                s.completed = true;
                if (s.label_addr != 0 and n < out.len) {
                    out[n] = .{ s.label_addr, s.label_value };
                    n += 1;
                }
                continue; // retired
            }
            if (!s.completed) {
                self.submissions[kept] = s.*;
                kept += 1;
            }
        }
        self.count = kept;
        return n;
    }
};

/// Legacy PS4 queue identity → (pipe, queue) on the shared path.
pub fn queueIdentity(pipe: u8, legacy_queue: u8) struct { pipe: u8, queue: u8 } {
    return .{ .pipe = pipe, .queue = legacy_queue % 8 };
}
