# Security lens reference

You are doing a **lightweight** security scan on this diff. This is not a
full audit — flag issues where the code change creates or worsens a security
risk. Over-flag; Phase 4 will filter.

## Categories to check

**Authorization & authentication.**
- New routes, API endpoints, or mutations without an auth check
- New fields exposed through responses that shouldn't be (e.g. internal IDs,
  credentials, PII)
- Permission checks that accept a broader role than intended
- Session handling changes (token lifetime, invalidation, refresh)

**Input validation & injection.**
- User-controlled input concatenated into SQL, shell commands, or HTML without
  escaping/parameterization
- File paths built from user input without sanitization (path traversal)
- Regex or parser changes that accept previously-rejected malformed input

**Secrets & sensitive data.**
- Hardcoded API keys, tokens, passwords, or connection strings
- Sensitive values logged (passwords, tokens, PII, auth headers)
- Debug output or error messages that leak internal structure or secrets

**Cryptography.**
- New crypto primitives (if the project already has conventions, flag
  deviation; do not recommend specific algorithms beyond that)
- Random values used where cryptographic randomness is required

**Cross-cutting security patterns.**
- Race conditions in access checks (TOCTOU)
- Error paths that bypass normal auth/validation flow
- New code that handles untrusted input and calls into a structural pattern
  the rest of the code assumes is trusted (structural-family reasoning)

## Scope guard

If the diff touches no security-adjacent surface (pure UI tweak, pure test
refactor, etc.), return an empty list. Do not reach for security findings
that don't apply.
