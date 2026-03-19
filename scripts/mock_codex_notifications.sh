#!/bin/zsh
set -euo pipefail

thread_payload='{"id":"thread-qa","preview":"Notification QA thread","createdAt":1742389200,"updatedAt":1742389200,"status":{"type":"idle"},"cwd":"/Users/tester/codextension","name":"Notification QA Thread"}'
did_emit_events=0

extract_request_id() {
  local line="$1"
  print -r -- "$line" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p'
}

emit_events() {
  sleep 1
  print -r -- "{\"jsonrpc\":\"2.0\",\"method\":\"thread/started\",\"params\":{\"thread\":$thread_payload}}"
  sleep 1
  print -r -- '{"jsonrpc":"2.0","id":"qa-user-input","method":"item/tool/requestUserInput","params":{"threadId":"thread-qa","turnId":"turn-qa","itemId":"item-input"}}'
  sleep 1
  print -r -- '{"jsonrpc":"2.0","id":"qa-approval","method":"item/commandExecution/requestApproval","params":{"threadId":"thread-qa","turnId":"turn-qa","itemId":"item-approval","reason":"Notification QA approval"}}'
  sleep 1
  print -r -- '{"jsonrpc":"2.0","method":"turn/completed","params":{"threadId":"thread-qa","turn":{"id":"turn-qa","status":"completed","error":null}}}'
  sleep 1
  print -r -- '{"jsonrpc":"2.0","method":"error","params":{"threadId":"thread-qa","turnId":"turn-qa-failed","willRetry":false,"error":{"message":"Notification QA failure"}}}'
}

while IFS= read -r line; do
  case "$line" in
    *'"method":"initialize"'*)
      request_id="$(extract_request_id "$line")"
      print -r -- "{\"jsonrpc\":\"2.0\",\"id\":${request_id:-1},\"result\":{\"userAgent\":\"mock-codex-notifications\"}}"
      ;;
    *'"method":"initialized"'*)
      if [[ "$did_emit_events" == "0" ]]; then
        did_emit_events=1
        emit_events &
      fi
      ;;
    *'"method":"thread/list"'*)
      request_id="$(extract_request_id "$line")"
      print -r -- "{\"jsonrpc\":\"2.0\",\"id\":${request_id:-1},\"result\":{\"data\":[$thread_payload],\"nextCursor\":null}}"
      ;;
    *'"method":"thread/resume"'*)
      request_id="$(extract_request_id "$line")"
      print -r -- "{\"jsonrpc\":\"2.0\",\"id\":${request_id:-1},\"result\":{\"thread\":$thread_payload}}"
      ;;
    *'"method":"thread/unsubscribe"'*)
      request_id="$(extract_request_id "$line")"
      print -r -- "{\"jsonrpc\":\"2.0\",\"id\":${request_id:-1},\"result\":{\"status\":\"ok\"}}"
      ;;
  esac
done
