# zclip

A tool to manage and sync your clipboard between devices.

To get started, build and install the program with a prefix of /usr/local (whatever you like works, just update the systemd unit file).

Maybe later I will write an install script people can pipe to bash etc.

```sh
zig build -Doptimize=safe
sudo install -m 755 -d zig-out /usr/local
mkdir -p ~/.config/systemd/user
cp zclip.service ~/.config/systemd/user/
systemctl --user daemon-reload && systemctl enable --now zclip
```

Now the daemon will be started, and stopped when you log out of your graphical session.

# Website

See the project website [@nullndvoid.xyz](https://nullndvoid.xyz/projects/zclip). It doesn't currently contain much but I will eventually get around to populating it with documentation, as well as publishing devlogs on there.

# TODOs

- CLI interface for listing clipboard items
- Nice GUI <-- Possibly as a separate app anyway? Qt perhaps or something Zig-native.
- System tray icon
- For files/large pastes, transmit the file lazily, with type file_preview or something similar.
  Then the data can be a thumbnail if present.
- TUI-style pickers/wizards if you do not specify any positional arguments.

Maybe something like this already exists but this would be a nice tool to have :)

In fact, you could probably use KDE Connect but I have had my issues with it, and it has many
features I am less worried about.

# Authors

- J. Hinchliffe (nullndvoid)
