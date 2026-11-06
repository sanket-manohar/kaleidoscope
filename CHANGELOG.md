## 1.0.0

First public release.

* Capture every AI call from any provider: `http.Client` wrapper, Dio
  interceptor, `track` / `trackStream` wrappers, on-device models and
  server-reported usage.
* Recognises OpenAI-compatible, Anthropic, Gemini, Ollama and Cohere APIs
  automatically, including streaming (SSE and NDJSON) with time to first token.
* Module, page and section tagging through zones, widget scopes and a
  navigator observer.
* Encrypted storage (SQLCipher, key in Keychain / Keystore) with metadata-only,
  redacted and full prompt modes, PII redaction and retention policies.
* Updatable price table with prompt-cache discounts, remote price files and
  pre-call cost estimates.
* Analytics: breakdowns, trends, Holt forecasts, anomalies, budgets, latency
  percentiles and plain-language insights.
* Drop-in analytics dashboard, chart widgets and a floating debug overlay.
* JSON, CSV and HTML export; opt-in sinks for your server, PostHog, Mixpanel
  and OpenTelemetry (including Langfuse).
* Optional provider fallback router with a circuit breaker.
