# Security

## Reporting a vulnerability

Please use **Security → Report a vulnerability** in this repository when private
vulnerability reporting is available. Do not post tokens, private project content
or an exploitable security issue in a public issue or pull request.

If private reporting is unavailable, open a minimal public issue asking the
maintainer to enable it, without disclosing vulnerability details or credentials.
There is currently no guaranteed response time or published support schedule.

## Credentials and local data

Issues can use your existing GitHub CLI login or a personal token in the macOS
Keychain. Preferences and project caches are stored locally, outside the source
checkout. Cache files may contain private issue content; treat them as private.

Grant only the GitHub access needed for your projects and repositories. Revoke
compromised tokens in GitHub and authenticate again. Do not paste credentials
into issue descriptions, screenshots or diagnostic logs.

Attachments are uploaded only when creating an issue. Images and videos use
GitHub's upload endpoint; attachment redirects are rejected. Markdown previews
are sanitized and do not load embedded images.

Builds produced by the provided script are ad-hoc signed, not notarized releases.
Review source and dependencies before distributing your own build.
