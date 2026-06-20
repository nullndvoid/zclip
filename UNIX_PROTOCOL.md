# Unix Protocol

When a local client and daemon want to communicate, they shall use the
protocol as defined in this document.

There are no problems with version mismatches unlike with an internet protocol, since we will
distribute zclip as a single binary.

From now on C shall denote a local client, and D will denote the daemon.

For easier debugging as well as scripting, we will send messages in JSON.

## Notes

By default, the daemon will store clippings, even if no client has connected yet. I might make
this configurable later.

I will refer to JSON objects defined in `src/schema`, but may include some examples here anyway.


## Actions

The client wants notifying when new clipboard entries are pushed to the system clipboard.
