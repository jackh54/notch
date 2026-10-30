#!/usr/bin/env bash
# Plays fake Claude Code hook events into the running app so every Agents state can be
# seen on the real notch: a working session with tools and tokens, two approvals at once,
# a question, then a finished session. Nothing here touches a real agent.
#
# Usage: scripts/agent-demo.sh
set -euo pipefail

DOMAIN="theboringteam.boringnotch"
PORT="$(defaults read "$DOMAIN" agentsHookPort 2>/dev/null || echo 47615)"
TOKEN="$(defaults read "$DOMAIN" agentsHookToken 2>/dev/null || true)"
[ -n "$TOKEN" ] || { echo "No hook token found. Launch the app first." >&2; exit 1; }

BASE="http://127.0.0.1:$PORT/hook/claude?token=$TOKEN"
SESSION="demo-$(date +%s)"
CWD="$HOME/Documents/GitHub/notch"

# Makes a fake transcript so token usage flows the same way as a real session.
FOLDER="$HOME/.claude/projects/$(printf '%s' "$CWD" | tr -c 'a-zA-Z0-9' '-')"
TRANSCRIPT="$FOLDER/$SESSION.jsonl"
mkdir -p "$FOLDER"
trap 'rm -f "$TRANSCRIPT"' EXIT

send() { # event [extra json fields] [wait seconds]
  local body="{\"session_id\":\"$SESSION\",\"cwd\":\"$CWD\",\"transcript_path\":\"$TRANSCRIPT\",\"hook_event_name\":\"$1\"${2:+,$2}}"
  curl -s --max-time "${3:-5}" -H 'Content-Type: application/json' -H 'Expect:' \
    --data-binary "$body" "$BASE&wait=${3:-5}" >/dev/null || true
}

tokens() { # message id, output tokens
  printf '{"type":"assistant","message":{"id":"%s","model":"claude-opus-5-5","content":[{"type":"text","text":"Working on it."}],"usage":{"input_tokens":400,"output_tokens":%s,"cache_creation_input_tokens":0,"cache_read_input_tokens":150000}}}\n' \
    "$1" "$2" >>"$TRANSCRIPT"
}

tool() { # name, detail key, detail, id
  send PreToolUse "\"tool_name\":\"$1\",\"tool_use_id\":\"$4\",\"tool_input\":{\"$2\":\"$3\"}"
  sleep 1.5
  send PostToolUse "\"tool_name\":\"$1\",\"tool_use_id\":\"$4\""
}

echo "Session $SESSION: working"
send SessionStart
send UserPromptSubmit
tokens m0 10
sleep 2.5
for i in 1 2 3; do
  tokens "m$i" $((i * 4000))
  tool Bash command "swift test --filter Demo$i" "t$i"
  tool Read file_path "$CWD/boringNotch/Agents/AgentManager.swift" "r$i"
  sleep 2
done
send SubagentStart
tool Grep pattern "currentRequest" g1
send SubagentStop

echo "Two approvals: answer them in the notch, or wait for the 60s timeout"
send PermissionRequest '"tool_name":"Bash","tool_input":{"command":"rm -rf build"},"permission_suggestions":[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"rm -rf build"}],"behavior":"allow","destination":"localSettings"}]' 60 &
sleep 2
send PermissionRequest '"tool_name":"Edit","tool_input":{"file_path":"'"$CWD"'/README.md","old_string":"one\ntwo\nthree","new_string":"one\n2\nthree"}' 60 &
wait

echo "Question: answer it in the notch, or wait for the 60s timeout"
send PreToolUse '"tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which demo ending do you want?","header":"Ending","multiSelect":false,"options":[{"label":"Finished","description":"End the demo normally"},{"label":"Encore","description":"Same ending, more applause"}]}]}' 60

echo "Finished"
tokens m9 2500
sleep 3
send Stop '"last_assistant_message":"## Demo finished\n\nEvery state was **shown**, including `particles`.\n\n- Tools\n- Approvals\n- Questions"'
sleep 8
send SessionEnd
