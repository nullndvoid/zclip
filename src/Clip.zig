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

//! A clipboard entry and associated data.

const std = @import("std");

/// Owned by the backend, which will be owned by the `Manager`. Should be
/// cleaned up on deinit.
data: []const u8,
/// Assumed to be correct. If we are reading from system clipboard, this is assumed valid.
/// For writes, we perform no checks on the validity of the (data, mimetype) pair.
mime_type: []const u8,
