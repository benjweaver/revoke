#!/bin/zsh
# Tries to get around a build of Revoke before it's released, in the "macOS 27" UTM VM.
# Scripts/release.sh runs it on the build it's about to publish and stops if it fails;
# run it by hand on any build:
#
#   Scripts/escape-test.sh                      # build/export/Revoke.app
#   APP=/path/to/Revoke.app Scripts/escape-test.sh
#
# What it checks:
# 1. Update. Installs the latest release from the Homebrew tap, then the build over it,
#    and checks the build's filter took over and answers Revoke. A filter that comes up
#    unable to hear Revoke keeps blocking but can't be changed, and nothing else shows it.
# 2. Local Network. Blocks a test app and checks it can't reach the VM's gateway from its
#    own process, from a command it runs, or from a helper it disclaims and hands to
#    launchd, and that it can again once the block is lifted.
# 3. Tampering. Empties Revoke's saved list of blocked apps while Revoke is quit, and
#    checks the block holds and the list comes back.
# 4. Internet. Limits the test app to one host and checks it reaches that host and not
#    another, through curl and URLSession, nor with a TLS hello that names the other host
#    sent to the allowed host's address, and that the local network still works.
# 5. Requests. Asks for the internet for a minute with `Revoke --request`, says yes, and
#    checks the limit lifts and then comes back by itself.
#
# Needs:
# - The "macOS 27" VM with Revoke set up in it: its network filter allowed and on. The
#   script installs apps and flips switches; it doesn't grant anything.
# - agent-guides' mac.sh (MAC_SH) and ssh to the VM as macos27 (MAC_HOST), as
#   Scripts/screenshots.sh does. The VM needs the internet, for the two test hosts.
# - Swift on this Mac, to build the test app in Scripts/escape-test.
# - Nobody using the VM's screen meanwhile: the script clicks in it.
#
# It clicks the Watched row's switches by position, since macOS doesn't offer the panel's
# switches to accessibility there, and checks each click against Revoke's own lists. If
# the panel's layout changes, the offsets in `column` and `header_y` are what to update.
#
# The VM is left as it was: the test app is removed, the blocks and limits it set are
# lifted, Revoke's watch list is put back, and the VM is shut down if this script started it.
set -eu
cd "$(dirname "$0")/.."

MAC_SH=${MAC_SH:-$HOME/Dev/agent-guides/machines/bens-macbook-pro/tools/mac.sh}
host=${MAC_HOST:-macos27}
app=${APP:-build/export/Revoke.app}
tap=benjweaver/homebrew-revoke
allowed_host=example.com
other_host=example.org
test_id=com.example.revoke-escape-test
test_app=/Applications/EscapeTest.app
log=/tmp/revoke-escape-test.log
defaults_domain=dev.benjweaver.Revoke
# Longer than a run takes; cleanup ends it sooner.
awake_seconds=3600

mac() { zsh "$MAC_SH" "$@"; }
guest() { ssh -o ConnectTimeout=15 -o ServerAliveInterval=5 "$host" "$@"; }

failures=0
pass() { print -r -- "  ok    $1"; }
fail() { print -r -- "  FAIL  $1"; failures=$(( failures + 1 )); }
die() { print -u2 -r -- "escape-test.sh: $1"; exit 2; }

[[ -d $app ]] || die "no app at $app; run Scripts/build.sh first, or set APP"
[[ -f $MAC_SH ]] || die "no mac.sh at $MAC_SH"

saved_watched=
cleanup() {
	local rc=$?
	trap - EXIT INT TERM
	print "==> Putting the VM back"
	guest "pkill -f 'caffeinate -d -u -t $awake_seconds'" >/dev/null 2>&1 || true
	guest "pkill -x EscapeTest; rm -rf $test_app $log $log.orphan /tmp/revoke-escape-app.zip /tmp/revoke-escape-test.zip" >/dev/null 2>&1 || true
	# Lift whatever the run left, through the panel like everything else.
	if panel_open 2>/dev/null; then
		[[ $(listed localNetworkBlocked) == yes ]] && click_header local-network || true
		[[ $(listed internetLimited) == yes ]] && click_header internet || true
		mac key esc >/dev/null 2>&1 || true
	fi
	guest "osascript -e 'tell application \"System Settings\" to quit'" >/dev/null 2>&1 || true
	mac quit Revoke >/dev/null 2>&1 || true
	sleep 1
	if [[ -n $saved_watched ]]; then
		guest "defaults write $defaults_domain watched -array $saved_watched; defaults delete $defaults_domain extraInternetHosts" >/dev/null 2>&1 || true
	else
		guest "defaults write $defaults_domain watched -array; defaults delete $defaults_domain extraInternetHosts" >/dev/null 2>&1 || true
	fi
	mac restore >/dev/null 2>&1 || true
	mac down || true
	(( rc == 0 && failures > 0 )) && rc=1
	exit $rc
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# MARK: - Revoke's panel

# Opens the panel and prints its rectangle, "x y w h" in points.
panel_rect() {
	local i
	for i in {1..10}; do
		mac windows Revoke | awk -F'\t' '$4 == 25 { print $5, $6, $7, $8; found = 1; exit } END { exit !found }' && return 0
		sleep 1
	done
	return 1
}

# Opens the panel unless it's open already: clicking the menu bar icon again would close it.
panel_open() {
	mac windows Revoke | awk -F'\t' '$4 == 25 { found = 1 } END { exit !found }' && return 0
	mac menu Revoke >/dev/null
	sleep 2
	panel_rect >/dev/null
}

# The x of a column's switch, counted from the right edge of the panel's window: 14
# points of shadow, 16 of padding, then columns 56 wide with 4 between (PanelLayout).
column() {
	local from_right
	case $1 in
		all-access) from_right=0 ;;
		other) from_right=1 ;;
		links) from_right=2 ;;
		internet) from_right=3 ;;
		local-network) from_right=4 ;;
		*) die "no column $1" ;;
	esac
	print $(( $2 + $3 - 14 - 16 - 27 - 60 * from_right ))
}
# The Watched row's switches sit this far below the top of the panel's window, shadow
# included, while the status under the title is one line.
header_y=144

# Clicks the Watched row's switch in a column, which acts on every watched app.
click_header() {
	local rect x y
	rect=($(panel_rect)) || die "Revoke's panel isn't on screen"
	x=$(column "$1" $rect[1] $rect[3])
	y=$(( rect[2] + header_y ))
	guest "/usr/local/bin/gui click $x $y" >/dev/null
	sleep 4
}

# Whether the test app is in one of Revoke's lists, as Revoke last heard from its filter.
listed() {
	guest "defaults read $defaults_domain $1 2>/dev/null" | grep -q "$test_id" && print yes || print no
}

# Flips a column for the watched apps and checks the test app landed in or out of a list.
set_column() {
	local column=$1 list=$2 want=$3
	panel_open || die "couldn't open Revoke's panel"
	click_header "$column"
	guest "osascript -e 'tell application \"System Settings\" to quit'" >/dev/null 2>&1 || true
	[[ $(listed "$list") == $want ]] || die "clicking $column didn't change $list; has the panel's layout moved? (see column and header_y)"
	mac key esc >/dev/null 2>&1 || true
}

# MARK: - The test app's results

# Prints the test app's next whole line of results, taken after everything before now.
results() {
	local after=$(guest date +%s) line i
	for i in {1..60}; do
		# Each line starts with when its round began; one begun earlier may have tried
		# some routes before the switch was flipped.
		line=$(guest "awk -v after=$after '\$1 > after' $log 2>/dev/null | head -1") || true
		[[ -n $line ]] && { print -r -- "$line"; return 0; }
		sleep 2
	done
	die "the test app wrote no results"
}

# expect LINE KEY VALUE WHAT
expect() {
	local got=${${(M)${(z)1}:#$2=*}#*=}
	if [[ $got == $3 ]]; then pass "$4"; else fail "$4 ($2 was ${got:-missing}, wanted $3)"; fi
}

# MARK: - Installing

install_app() {
	local zip=/tmp/revoke-escape-app.zip work
	work=$(mktemp -d)
	ditto -c -k --keepParent "$1" "$work/app.zip"
	scp -q "$work/app.zip" "$host:$zip"
	rm -rf "$work"
	guest "pkill -x Revoke; sleep 1; rm -rf /Applications/Revoke.app; ditto -x -k $zip /Applications/ && rm -f $zip"
}

# Starts Revoke and waits for its filter to be the build in /Applications, which drops
# the ssh connection for a moment when one filter replaces another.
start_revoke() {
	guest '(nohup open /Applications/Revoke.app >/dev/null 2>&1 &)' || true
	local want i now
	sleep 6
	want=$(guest "defaults read /Applications/Revoke.app/Contents/Info CFBundleVersion")
	for i in {1..20}; do
		now=$(guest "systemextensionsctl list 2>/dev/null | grep 'dev.benjweaver.Revoke.Filter' | grep 'activated enabled'" 2>/dev/null) || true
		[[ $now == *"/$want)"* ]] && { sleep 4; return 0; }
		sleep 3
	done
	return 1
}

# Whether Revoke and its filter can talk: launchd lists the filter's service, and Revoke
# hasn't logged a failure to reach it since it started.
filter_answers() {
	guest 'job=$(launchctl print system 2>/dev/null | grep -o "NetworkExtension.dev.benjweaver.Revoke.Filter[0-9.]*" | head -1)
		launchctl print "system/$job" 2>/dev/null | grep -q "endpoints" || { echo "launchd lists no service for $job"; exit 1; }
		n=$(/usr/bin/log show --last 45s --style compact --predicate "subsystem == \"dev.benjweaver.Revoke\" AND eventMessage CONTAINS \"reach the network filter\"" 2>/dev/null | grep -vc Timestamp)
		[ "$n" = 0 ] || { echo "Revoke logged $n failures to reach the filter"; exit 1; }'
}

# MARK: - The run

print "==> Starting the VM"
mac up
guest true || die "can't reach the VM as $host"
mac prep light >/dev/null
# The guest's display sleeps after ten idle minutes. Asleep, the panel's window reports
# another rectangle and clicks do nothing, so it's held awake for the whole run, and a
# key press wakes it if it had already gone.
guest "(nohup caffeinate -d -u -t $awake_seconds >/dev/null 2>&1 &); sleep 1; /usr/local/bin/gui key shift" >/dev/null 2>&1 || true
# Whatever the person watches, to put back afterward.
saved_watched=$(guest "defaults read $defaults_domain watched 2>/dev/null" | tr -d '()\n' | sed 's/,/ /g; s/  */ /g') || true
gateway=$(guest "route -n get default 2>/dev/null | awk '/gateway/ { print \$2 }'")
[[ -n $gateway ]] || die "the VM has no default gateway to test the local network with"
guest "nc -z -G 3 $gateway 53" >/dev/null 2>&1 || die "the VM's gateway $gateway doesn't answer on port 53"

print "==> Building the test app"
build=$(mktemp -d)
swiftc -O Scripts/escape-test/main.swift -o "$build/EscapeTest"
mkdir -p "$build/EscapeTest.app/Contents/MacOS"
mv "$build/EscapeTest" "$build/EscapeTest.app/Contents/MacOS/EscapeTest"
cat > "$build/EscapeTest.app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
	<key>CFBundleIdentifier</key><string>$test_id</string>
	<key>CFBundleName</key><string>EscapeTest</string>
	<key>CFBundleExecutable</key><string>EscapeTest</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>1.0</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>LSUIElement</key><true/>
</dict></plist>
EOF
codesign -f -s - -i "$test_id" "$build/EscapeTest.app" 2>/dev/null
ditto -c -k --keepParent "$build/EscapeTest.app" "$build/test.zip"
scp -q "$build/test.zip" "$host:/tmp/revoke-escape-test.zip"
rm -rf "$build"
guest "pkill -x EscapeTest; rm -rf $test_app $log $log.orphan; ditto -x -k /tmp/revoke-escape-test.zip /Applications/ && rm -f /tmp/revoke-escape-test.zip"

print "==> Update: the latest release, then this build over it"
read -r url sha version <<< "$(mac cask "$tap" revoke)"
mac quit Revoke >/dev/null 2>&1 || true
mac install "$url" "$sha" >/dev/null
start_revoke || die "the release's filter ($version) didn't come up; is the filter allowed in the VM?"
candidate="$(plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist") ($(plutil -extract CFBundleVersion raw "$app/Contents/Info.plist"))"
print "  from $version to $candidate"
install_app "$app"
# The watch list and the test's host are Revoke's ordinary settings, set while it's quit.
guest "defaults write $defaults_domain watched -array $test_id; defaults write $defaults_domain extraInternetHosts -array $allowed_host"
if start_revoke; then pass "this build's filter took over"; else fail "this build's filter didn't take over"; fi
if why=$(filter_answers 2>&1); then pass "Revoke reaches its filter after the update"; else fail "Revoke can't reach its filter after the update: $why"; fi

print "==> Before anything is blocked"
guest "open $test_app --args $gateway $allowed_host $other_host $log"
line=$(results)
for key in lan_direct lan_child lan_orphan net_allowed net_allowed_session net_other net_other_session net_fronted; do
	expect "$line" $key ok "the test app reaches everything ($key)"
done
(( failures == 0 )) || die "the test app can't reach its targets with nothing blocked, so the rest would prove nothing"

print "==> Local Network blocked"
set_column local-network localNetworkBlocked yes
line=$(results)
expect "$line" lan_direct no "a connection from the app itself is dropped"
expect "$line" lan_child no "a connection from a command it runs is dropped"
expect "$line" lan_orphan no "a connection from a helper it handed to launchd is dropped"
expect "$line" net_other ok "the internet is untouched"
if guest "nc -z -G 3 $gateway 53" >/dev/null 2>&1; then pass "an app that isn't blocked still reaches the gateway"; else fail "an app that isn't blocked lost the gateway too"; fi

print "==> Tampering with Revoke's saved list"
mac quit Revoke >/dev/null 2>&1 || true
sleep 1
guest "defaults write $defaults_domain localNetworkBlocked -array"
line=$(results)
expect "$line" lan_direct no "the block holds while Revoke is quit and its list is emptied"
start_revoke || fail "Revoke's filter wasn't there after relaunching"
line=$(results)
expect "$line" lan_direct no "the block holds after Revoke starts again"
if [[ $(listed localNetworkBlocked) == yes ]]; then pass "Revoke read the list back from its filter"; else fail "Revoke took the emptied list for the real one"; fi

print "==> Local Network allowed again"
set_column local-network localNetworkBlocked no
line=$(results)
expect "$line" lan_direct ok "the app reaches the gateway again"
expect "$line" lan_orphan ok "and so does its helper"

print "==> Internet limited to $allowed_host"
set_column internet internetLimited yes
line=$(results)
expect "$line" net_allowed ok "curl reaches the allowed host"
expect "$line" net_allowed_session ok "URLSession reaches the allowed host"
expect "$line" net_other no "curl to another host is dropped"
expect "$line" net_other_session no "URLSession to another host is dropped"
expect "$line" net_fronted no "a hello naming another host, sent to the allowed host's address, is dropped"
expect "$line" lan_direct ok "the local network is untouched"
if guest "curl -s -m 6 -o /dev/null https://$other_host"; then pass "an app that isn't limited still reaches the other host"; else fail "an app that isn't limited lost the other host too"; fi

print "==> A request for the internet, for a minute"
# Over ssh nothing stands behind the command, so the request names the app; Revoke says
# so in the question. The answer comes from clicking Yes by name.
guest "/Applications/Revoke.app/Contents/MacOS/Revoke --request 'revoke://request?access=internet&minutes=1&app=$test_id&reason=escape%20test' > /tmp/revoke-escape-answer.txt 2>&1 &
	sleep 4
	osascript -e 'tell application \"System Events\" to tell process \"Revoke\" to click button \"Yes\" of window 1' >/dev/null 2>&1
	sleep 3
	cat /tmp/revoke-escape-answer.txt; rm -f /tmp/revoke-escape-answer.txt" > /tmp/revoke-escape-answer.$$ 2>/dev/null || true
if grep -qx yes /tmp/revoke-escape-answer.$$; then pass "the command printed yes"; else fail "the command didn't print yes (it said: $(tr '\n' ' ' < /tmp/revoke-escape-answer.$$))"; fi
rm -f /tmp/revoke-escape-answer.$$
asked=$(date +%s)
line=$(results)
expect "$line" net_other ok "the other host is reachable while the allowance lasts"
# Until the minute is over, with a little to spare.
sleep $(( 75 - ($(date +%s) - asked) > 0 ? 75 - ($(date +%s) - asked) : 0 ))
line=$(results)
expect "$line" net_other no "the limit comes back by itself when the minute is up"

print "==> Internet allowed again"
set_column internet internetLimited no
line=$(results)
expect "$line" net_other ok "the app reaches the other host again"

print
if (( failures == 0 )); then
	print "escape-test.sh: everything held."
else
	print -u2 "escape-test.sh: $failures check$( (( failures == 1 )) || print s) failed."
	exit 1
fi
