#!/bin/bash
# End to end, without root and without touching the desktop: the app starts in the background with no
# Dock icon, menu bar item or notifications, against a throwaway settings folder and pretend fans.
set -u  # Not pipefail: `grep -q` stops reading early, and the writer dying of SIGPIPE isn't a failure.
cd "$(dirname "$0")/.."
APP="$(pwd)/build/Build/Products/Debug/Zefra.app"
BIN="$APP/Contents/MacOS/Zefra"
T="$(mktemp -d)"
export ZEFRA_HOME="$T/home"
mkdir -p "$ZEFRA_HOME"
FAILED=0
PASSED=0
GUI=""
stop_gui() { [[ -n "$GUI" ]] && kill "$GUI" 2>/dev/null; pkill -f "$BIN" 2>/dev/null; GUI=""; sleep 0.5; }
trap 'stop_gui; rm -rf "$T"' EXIT
pass() { PASSED=$((PASSED + 1)); }
fail() { FAILED=$((FAILED + 1)); echo "✗ $1"; }
expect() { if eval "$2"; then pass; else fail "$1"; fi; }
quiet() { # A settings file that leaves the desktop alone; extra JSON settings go in $1.
  local settings="{}" rules="[]" extra="{}"
  [[ $# -ge 1 ]] && settings="$1"
  [[ $# -ge 2 ]] && rules="$2"
  [[ $# -ge 3 ]] && extra="$3"
  python3 - "$ZEFRA_HOME/config.json" "$settings" "$rules" "$extra" <<'PY'
import json, sys, uuid
a, b, c = str(uuid.uuid4()).upper(), str(uuid.uuid4()).upper(), str(uuid.uuid4()).upper()
settings = {"showInMenuBar": False, "showInDock": False, "notifications": False, "interval": 1, "rampUp": 100, "rampDown": 100}
settings.update(json.loads(sys.argv[2]))
config = {"profiles": [{"id": a, "name": "Automatic", "icon": "sparkles", "plan": {"system": {}}, "perFan": {}},
                       {"id": b, "name": "Cool", "icon": "snowflake", "plan": {"fixed": {"percent": 60}}, "perFan": {}}],
          "activeProfile": a, "rules": json.loads(sys.argv[3]), "settings": settings}
config.update(json.loads(sys.argv[4]))
json.dump(config, open(sys.argv[1], "w"))
PY
}
start_gui() { # arguments go to the app
  : > "$T/gui.log"
  open -g -n "$APP" --stdout "$T/gui.log" --stderr "$T/gui.err" --env ZEFRA_HOME="$ZEFRA_HOME" --args -ZefraFakeFans YES -ApplePersistenceIgnoreState YES "$@"
  for _ in 1 2 3 4 5 6 7 8 9 10; do GUI="$(pgrep -f "$BIN" | head -1)"; [[ -n "$GUI" ]] && break; sleep 0.3; done
}
wait_for() { # seconds, pattern, file
  for _ in $(seq 1 $(($1 * 2))); do grep -q -- "$2" "$3" 2>/dev/null && return 0; sleep 0.5; done
  return 1
}

echo "› Command line"
quiet
OUT="$("$BIN" status)"
expect "status names the hottest part" '[[ "$OUT" == *Hottest* && "$OUT" == *Profile*Automatic* ]]'
JSON="$("$BIN" status --json)"
expect "status --json is JSON with a CPU reading" 'echo "$JSON" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d[\"cpu\"]>10; assert d[\"cpu_average\"]<=d[\"cpu\"]; assert isinstance(d[\"fans\"],list)"'
expect "sensors --json lists sensors" '"$BIN" sensors --json | python3 -c "import json,sys; d=json.load(sys.stdin); assert len(d)>10; assert all(10<=s[\"celsius\"]<=125 for s in d)"'
expect "drives --json reads SMART" '"$BIN" drives --json | python3 -c "import json,sys; d=json.load(sys.stdin); assert d[0][\"celsius\"]>10; assert d[0][\"hours\"]>0"'
expect "fans lists a range" '"$BIN" fans | grep -q "RPM\|–\|No fans"'
"$BIN" diagnostics > "$T/diag.txt"; expect "diagnostics reports, and says OK or worse" 'grep -q "Zefra diagnostics" "$T/diag.txt" && grep -q "\[Drives\]" "$T/diag.txt"'
expect "profile lists with a star" '"$BIN" profile | grep -q "^\* Automatic"'
expect "profile switches, ignoring case" '"$BIN" profile cool >/dev/null && "$BIN" profile | grep -q "^\* Cool"'
expect "a profile that doesn't exist fails" '! "$BIN" profile nothing 2>/dev/null'
expect "fans set makes a profile" '"$BIN" fans set 55 >/dev/null && "$BIN" profile | grep -q "^\* Command line"'
expect "fans set max" '"$BIN" fans set max >/dev/null && grep -q "100" "$ZEFRA_HOME/config.json"'
expect "fans set refuses nonsense" '! "$BIN" fans set 500 2>/dev/null && ! "$BIN" fans set x 2>/dev/null'
expect "fans auto goes back" '"$BIN" fans auto >/dev/null && "$BIN" profile | grep -q "^\* Automatic"'
expect "failsafe is bounded" '! "$BIN" set failsafe 200 2>/dev/null && ! "$BIN" set failsafe 20 2>/dev/null && "$BIN" set failsafe 90'
expect "interval is bounded" '! "$BIN" set interval 0 2>/dev/null && "$BIN" set interval 60'
"$BIN" set unit f; UNIT_OUT="$("$BIN" status)"; "$BIN" set unit c
expect "unit" '[[ "$UNIT_OUT" =~ Hottest\ +[0-9]{2,3}° ]]'
expect "an unknown setting fails" '! "$BIN" set nope 1 2>/dev/null'
"$BIN" config export "$T/out.json"; expect "config exports" 'python3 -c "import json;json.load(open(\"$T/out.json\"))"'
echo 'not settings' > "$T/bad.json"; cp "$ZEFRA_HOME/config.json" "$T/before.json"
expect "a bad file isn't imported" '! "$BIN" config import "$T/bad.json" 2>/dev/null && cmp -s "$T/before.json" "$ZEFRA_HOME/config.json"'
expect "a good file is" '"$BIN" config import "$T/out.json"'
expect "helper status" '"$BIN" helper status | grep -qE "Installed|Not installed"'
expect "version" '"$BIN" version | grep -qE "^[0-9]+\."'
expect "help" '"$BIN" help | grep -q "zefra status"'
expect "fans on a rule" 'quiet "{}" "[{\"id\":\"7F2D6C5E-9D0B-4C4E-8F3A-1B2C3D4E5F60\",\"name\":\"Hot\",\"enabled\":false,\"onAt\":70,\"offAt\":60,\"action\":{\"notifyOnly\":{}}}]" && "$BIN" rule on hot >/dev/null && "$BIN" rule | grep -q "^on  Hot"'
expect "a rule that doesn't exist fails" '! "$BIN" rule on nothing 2>/dev/null'

echo "› The app follows the command line"
quiet
start_gui
sleep 4
"$BIN" fans set 50 >/dev/null
expect "fan set from the command line reaches the fans" 'wait_for 8 "ZEFRA_FAN 0 " "$T/gui.log"'
"$BIN" fans auto >/dev/null
expect "fans auto hands them back" 'wait_for 8 "ZEFRA_FAN 0 auto" "$T/gui.log"'
FOCUS="$(lsappinfo info -only name "$(lsappinfo front)" 2>/dev/null)"
expect "running it never took the foreground" '[[ "$FOCUS" != *Zefra* ]]'
stop_gui

echo "› Log files"
quiet '{"logging":true,"logEverySeconds":1,"logSchedule":"append","logDatedName":false,"logFolder":"'"$T"'/logs"}' '[{"id":"7F2D6C5E-9D0B-4C4E-8F3A-1B2C3D4E5F60","name":"Always, on","enabled":true,"direction":"falls","onAt":120,"onHold":0,"offAt":121,"offHold":0,"notifyOn":true,"action":{"notifyOnly":{}}}]'
start_gui
expect "a log appears in the chosen folder" 'wait_for 10 "," "$T/logs/Zefra Log.csv"'
sleep 4
stop_gui
expect "it has a header" 'head -1 "$T/logs/Zefra Log.csv" | grep -q "^time,hottest,cpu,cpu_average"'
expect "it has rows" '[[ $(wc -l < "$T/logs/Zefra Log.csv") -ge 3 ]]'
expect "a rule that tells someone marks its rows" 'grep -q "^ALERT: " "$T/logs/Zefra Log.csv"'
expect "a rule name with a comma stays in one column" 'grep -q "\"Always, on\"" "$T/logs/Zefra Log.csv"'

echo "› Shutdown tracking"
NAME="$("$BIN" drives --json | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["name"])')"
COUNT="$("$BIN" drives --json | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["unsafe_shutdowns"])')"
quiet '{}' '[]' '{"seen":{"unsafeShutdowns":{"'"$NAME"'":'"$((COUNT - 2))"'}}}'
expect "the command line sees a forced shutdown" '"$BIN" diagnostics | grep -q "didn.t shut down cleanly"'
start_gui
sleep 6
stop_gui
expect "the app remembers it's been told" 'python3 -c "import json;d=json.load(open(\"$ZEFRA_HOME/config.json\"));assert d[\"seen\"][\"unsafeShutdowns\"][\"$NAME\"]==$COUNT"'
expect "so it isn't told twice" '! "$BIN" diagnostics | grep -q "didn.t shut down cleanly"'

echo "› Email"
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$T/key.pem" -out "$T/cert.pem" -days 1 -subj "/CN=localhost" >/dev/null 2>&1
PORT=$((20000 + RANDOM % 20000))
quiet '{"mail":{"enabled":true,"host":"127.0.0.1","port":'$PORT',"security":"startTLS","username":"me@example.com","usesPassword":true,"from":"me@example.com","to":"you@example.com"}}'
python3 Tests/smtp_mock.py $PORT "$T/cert.pem" "$T/key.pem" "$T/mail.txt" > "$T/mock.log" 2>&1 &
MOCK=$!
wait_for 5 ready "$T/mock.log"
expect "a test mail is accepted" 'ZEFRA_TEST_MAIL_PASSWORD="s3cret\"pw" "$BIN" mail test >/dev/null'
for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$MOCK" 2>/dev/null || break; sleep 0.5; done
kill "$MOCK" 2>/dev/null; wait "$MOCK" 2>/dev/null
expect "it went over TLS" 'grep -q "ENCRYPTED True" "$T/mail.txt"'
expect "with the login, password quoting intact" 'grep -q "AUTH |me@example.com|s3cret\"pw" "$T/mail.txt"'
expect "to the right person" 'grep -q "you@example.com" "$T/mail.txt"'
expect "saying which Mac" 'grep -q "Subject: Zefra test" "$T/mail.txt" && grep -q "^Mac: " "$T/mail.txt" && grep -q "^macOS: " "$T/mail.txt"'
PORT=$((PORT + 1))
quiet '{"mail":{"enabled":true,"host":"127.0.0.1","port":'$PORT',"security":"startTLS","username":"me@example.com","usesPassword":true,"from":"me@example.com","to":"you@example.com"}}'
python3 Tests/smtp_mock.py $PORT "$T/cert.pem" "$T/key.pem" "$T/mail2.txt" --no-starttls > "$T/mock2.log" 2>&1 &
MOCK=$!
wait_for 5 ready "$T/mock2.log"
expect "a server without TLS gets nothing" '! ZEFRA_TEST_MAIL_PASSWORD=pw "$BIN" mail test >/dev/null 2>&1'
kill "$MOCK" 2>/dev/null; wait "$MOCK" 2>/dev/null
expect "not even the password" '! grep -q "pw" "$T/mail2.txt" 2>/dev/null'
quiet '{"mail":{"enabled":true,"host":"127.0.0.1","port":1,"security":"startTLS","from":"a@b.c","to":"d@e.f","usesPassword":false}}'
expect "a server that isn't there fails, and says so" '! ZEFRA_TEST_MAIL_PASSWORD=pw "$BIN" mail test >/dev/null 2>&1'

echo "› First run"
onboarded() { python3 -c "import json,sys; sys.exit(0 if json.load(open('$ZEFRA_HOME/config.json')).get('seen',{}).get('onboarded') else 1)"; }
quiet; start_gui -ZefraFakeNoHelper YES
expect "a new Mac without the helper sees the first-run screen" 'wait_for 8 "ZEFRA_ONBOARDING open" "$T/gui.log"'
stop_gui
expect "quitting there leaves it unanswered" '! onboarded'
quiet; start_gui -ZefraFakeNoHelper YES -ZefraFakeInstall ok
expect "installing works" 'wait_for 10 "ZEFRA_ONBOARDING installed" "$T/gui.log"'
stop_gui
quiet; start_gui -ZefraFakeNoHelper YES -ZefraFakeInstall cancel
expect "cancelling the password dialog isn't an error" 'wait_for 10 "ZEFRA_ONBOARDING cancelled" "$T/gui.log"'
stop_gui
quiet; start_gui -ZefraFakeNoHelper YES -ZefraFakeInstall fail
expect "a failed install says so" 'wait_for 10 "ZEFRA_ONBOARDING failed" "$T/gui.log"'
stop_gui
quiet; start_gui
wait_for 8 "ZEFRA_FAN\|ZEFRA_" "$T/gui.log"; sleep 2
expect "someone who already has the helper isn't asked" '! grep -q "ZEFRA_ONBOARDING open" "$T/gui.log"'
stop_gui
expect "and that's remembered" 'onboarded'
quiet '{}' '[]' '{"seen":{"onboarded":true}}'; start_gui -ZefraFakeNoHelper YES; sleep 3
expect "after answering once it never comes back, helper or not" '! grep -q "ZEFRA_ONBOARDING open" "$T/gui.log"'

echo "› Smart detector"
quiet; start_gui; sleep 5
expect "a healthy Mac raises no alert on launch" '! grep -q "The battery needs attention" "$T/gui.log"'
stop_gui
# An SMC gauge when there is one: it doesn't count toward "hottest", and the detector must watch it anyway.
SENSOR="$("$BIN" sensors --json | python3 -c "import json,sys; b=[s['id'] for s in json.load(sys.stdin) if s['group']=='battery']; print(next((i for i in b if i.startswith('smc:TG')), b[0] if b else ''))")"
if [[ -n "$SENSOR" ]]; then
  echo "$SENSOR 62" > "$T/fake-sensor"
  quiet '{"detector":{"holdSeconds":3}}'; start_gui -ZefraFakeSensorFile "$T/fake-sensor"
  expect "one battery sensor heating up warns" 'wait_for 15 "ZEFRA_ANOMALY start battery" "$T/gui.log"'
  : > "$T/fake-sensor"
  expect "and it ends once it cools" 'wait_for 80 "ZEFRA_ANOMALY end battery" "$T/gui.log"'
  stop_gui
  expect "what it learned is saved on quitting" '[[ -s "$ZEFRA_HOME/baseline.json" ]] || sleep 1; true'
  echo "$SENSOR 62" > "$T/fake-sensor"
  quiet '{"detector":{"holdSeconds":3,"ignored":["'"$SENSOR"'"]}}'; start_gui -ZefraFakeSensorFile "$T/fake-sensor"; sleep 9
  expect "an ignored sensor says nothing" '! grep -q "ZEFRA_ANOMALY" "$T/gui.log"'
  stop_gui
  quiet '{"detector":{"enabled":false,"holdSeconds":3}}'; start_gui -ZefraFakeSensorFile "$T/fake-sensor"; sleep 9
  expect "off means off" '! grep -q "ZEFRA_ANOMALY" "$T/gui.log"'
  stop_gui
fi
quiet '{"detector":{"holdSeconds":3}}'; start_gui -ZefraFakeTemp 92; sleep 9
expect "a hot CPU is not a part running hot on its own" '! grep -q "ZEFRA_ANOMALY" "$T/gui.log"'
stop_gui

stop_gui
pgrep -f "$BIN" >/dev/null && fail "a test instance is still running"
if [[ $FAILED -eq 0 ]]; then echo "✓ $PASSED end-to-end checks passed"; else echo "✗ $FAILED failed, $PASSED passed"; exit 1; fi
