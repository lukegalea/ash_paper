# Security policy

## Reporting a vulnerability

Please report vulnerabilities privately through GitHub's private vulnerability reporting:
<https://github.com/lukegalea/ash_paper/security/advisories/new>. Do not open a public issue or pull request
for a suspected vulnerability.

## Supported versions

Only `main` receives fixes.

## Scope

The PDF reader parses bytes that may come from a third party: unbounded inflation, recursion or memory use in it is
in scope. So is any way for a theme or clause to inject Typst source.
