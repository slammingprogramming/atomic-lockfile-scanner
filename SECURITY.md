# Security policy

## Scope

The only program here is `atomic-arch-check.sh`. A security problem is something that lets the scan be abused, for example a crafted file name or file content in a package or cache directory that makes the script run code, write a file, or leak data.

Not a security problem: a campaign indicator the script misses, or a false positive. Open an ordinary issue for those, with a source link.

## Reporting

Please do not open a public issue for a vulnerability. Send a private message through SimpleX:

https://smp14.simplex.im/a#3gZ-zeHs4QrFZKLAN0o3SC_XQJXhj1eYBVTO_c0FAtg

Include the script version (the commit), what you did, and what happened. Replies are best effort.

## Supported versions

Only the latest commit on `main`.
