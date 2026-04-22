#!/usr/bin/env bash
# dep-check.sh — SessionStart hook: warn if required CLI tools are missing.
# Soft warning only — never fails the session. Output is injected into
# Claude's session context, so keep it focused on hard requirements.

missing=()
for tool in uv jq gh git; do
  command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
done

if [ "${#missing[@]}" -gt 0 ]; then
  echo "[adams-review] WARNING: missing required tool(s): ${missing[*]}"
  case "$(uname -s)" in
    Darwin)
      echo "[adams-review]   macOS:   brew install ${missing[*]}" ;;
    Linux)
      echo "[adams-review]   Linux:   apt install ${missing[*]}  # or distro equivalent" ;;
    MINGW*|MSYS*|CYGWIN*)
      echo "[adams-review]   Windows: choco install ${missing[*]}  # or scoop install ${missing[*]}" ;;
  esac
fi

exit 0
