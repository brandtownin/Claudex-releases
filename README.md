# Claudex Releases

Public immutable release artifacts for Claudex. Source code remains in the private Claudex repository.

## Public RunOrc installer bootstrap

`bootstrap.sh` provides the machine-accessible installation entrypoint,
independent of Vercel's browser-protected Internal Preview. Its initial bytes
come from RunOrc source commit
`8afc0b4e871c116558b4ea3eee8c5c378753ca3c:public/bootstrap.sh`.

RunOrc's generated commands pin both this repository's exact Git commit and
the bootstrap SHA-256 before executing it with sudo. The bootstrap itself
validates signed release channels, signed manifests and package checksums.
Updating this entrypoint requires coordinating the RunOrc command generator
and release metadata gate. Publishing it does not promote a signed runtime
channel or activate the public Beta website.
