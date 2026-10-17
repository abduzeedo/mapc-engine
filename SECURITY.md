# Security

MacadeKit downloads and runs software on people's Macs, so security problems matter more here than bugs.

## Reporting a problem

Please don't open a public issue or pull request for a security problem. Report it privately instead:

- On GitHub: the **Security** tab of this repository, then **Report a vulnerability**.
- Or by email: support@mapc.games, with "Security" in the subject.

Say what the problem is, how to reproduce it, and which version (tag) or commit you tested. We'll reply within a
few days, keep you updated while we fix it, and credit you in the release notes if you'd like.

## What counts

For example: a download that isn't checked against its pinned SHA-256, a way for a game, store or web page to run
code outside Wine's environment or read files it shouldn't, store login tokens ending up in logs or readable by
other users, or anything that could get Apple software or private data into a build or this repository.

## Supported versions

Only the latest release is fixed. MaPC updates to it through its normal updates.
