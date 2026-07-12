// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 J. Hinchliffe (nullndvoid)
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.

//! A clipboard entry and associated data. Data and MIME Type are heap alloced.
//! Ownership follows the holder.

const std = @import("std");

/// Allocated by the producing backend; ownership transfers with the clip,
/// so whoever consumes it frees it (with the same allocator the backend
/// was given for payloads).
data: []const u8,
/// Assumed to be correct. If we are reading from system clipboard, this is assumed valid.
/// For writes, we perform no checks on the validity of the (data, mimetype) pair.
mime_type: []const u8,

/// Set if the clipping is text. Not assumed UTF-8 although this check could be added later.
is_text: bool,

/// Set to 0 if system local, else the originating daemon ID > 0.
origin_id: u64 = 0,
