# Request Logging Default-On with Credential Masking

Default-on LLM request logging with a 50 MB cap and credential masking was chosen over opt-in logging: the log category `llm` defaults to ON for missing-key installs (new and existing alike), the log total is capped at 50 MB with oldest-first eviction, and credential-bearing headers (`authorization`, `proxy-authorization`, `x-api-key`, `x-goog-api-key`, `api-key`) are masked in log output to the first 7 characters plus the remaining length (`Bearer [45 more]`) so the logs stay fully debuggable without credentials at rest. Issue #196.

## Considered Options

- **All categories on**: rejected — tts/search/flutter logs are noise for support; kept user-opt-in.
- **Log headers unmasked**: rejected — with logging on by default, API keys would land in plaintext `logs/*.txt` on every install; masking costs nothing diagnostically (bodies keep full fidelity).
- **Redaction via full suppression**: rejected — `***` would hide whether the scheme/header shape is correct, which matters when debugging provider-specific auth issues.

## Consequences

- Defaults apply to any install missing the key, including existing installs that never touched the toggles — logging becomes active and the 50 MB cap (previously unlimited) starts being enforced at startup cleanup.
- Bodies remain unmasked by design; the accepted residual exposure is conversation content at rest, not credentials.
