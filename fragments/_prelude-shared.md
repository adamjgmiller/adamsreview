# Shared prelude — applies to every `/adamsreview:*` command

These rules apply across every phase of every adamsreview command that
dispatches sub-agents or invokes helper scripts. Read once at
command-start; individual phase fragments assume you know these and
do not re-state them.

## 1. After every sub-agent returns

Before branching on its content — immediately, in order:

1. **Extract the token count.** The Agent tool result exposes a
   structured `usage` field when available; otherwise parse
   `<usage>total_tokens: N</usage>` from the sub-agent's output text.
   On parse failure, log with tokens value `null` (i.e. `--tokens null`) per DESIGN §11.
2. **Call `log-tokens.sh`** with the phase, agent_role, agent_id,
   model, finding_id (when applicable), and the tokens value. This
   is the DESIGN §24.4 invariant: every sub-agent's cost is accounted
   even when its output fails to parse.
3. **Parse the sub-agent's structured output** per the dispatching
   fragment's schema. Light repair (strip code fences, extract JSON
   block) is OK. One retry allowed on parse failure with a prompt
   addendum. Drop-with-note on second failure.

## 2. Helper-script errors — error-as-prompt

Helper-script errors follow DESIGN §8.6's error-as-prompt convention:
ERROR → context → Valid values → Did you mean → Action. When a helper
exits non-zero, parse the stderr, adjust your inputs per the guidance,
retry ONCE. Only escalate to the user if the second retry also fails.
