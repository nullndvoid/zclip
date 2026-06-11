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

const wayland = @import("wayland");
const wl = wayland.client.wl;
pub const Manager = wayland.client.ext.DataControlManagerV1;
pub const Device = wayland.client.ext.DataControlDeviceV1;
pub const Source = wayland.client.ext.DataControlSourceV1;

pub fn dataControlDeviceListener(dev: *Device, ev: Device.Event, _: void) void {
    _ = dev;
    switch (ev) {
        .data_offer => {
            const data_offer = ev.data_offer.id;
            _ = data_offer;
        },
        .finished => {},
        .primary_selection => {},
        .selection => {},
    }
}
