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
#    launchd, and that it can again once the block is lifted. The same for two subnets
#    outside the private ranges that the VM is put on for the run: a carrier-grade NAT
#    one and a global IPv6 one.
# 3. Tampering. Empties Revoke's saved list of blocked apps while Revoke is quit, and
#    checks the block holds and the list comes back.
# 4. Internet. Limits the test app to one host and checks it reaches that host and not
#    another, through curl and URLSession, nor with a TLS hello that names the other host
#    sent to the allowed host's address, and that the local network still works.
#    It empties macOS's cache of names first, so the app has to look them up through a
#    DNS server on the local network while blocked, and through one on the internet
#    while limited: both must still work.
# 5. Requests. Asks for the internet for a minute with `Revoke --request`, says yes, and
#    checks the limit lifts and then comes back by itself.
# 6. Everything at once. Switches off all the test app's access and checks every reset
#    Revoke ran with tccutil worked, and that macOS knows each service Revoke names.
# 7. Links. With the test app's links held, opens one and checks it reaches the app only
#    after Yes, and that `Revoke --restore-links` gives the link back only after Yes.
# 8. The time limit. Sets the shortest one, 15 minutes, and checks the running app keeps
#    the local network until then and loses it after. SKIP_TIME_LIMIT=1 leaves this out
#    of a run by hand; a release always runs it.
#
# Needs:
# - The "macOS 27" VM with Revoke set up in it: its network filter allowed and on. The
#   script installs apps and flips switches. The one thing it grants is macOS's own
#   Local Network question about the test app, which it answers Allow: with that
#   refused, macOS would do the blocking and Revoke's filter would never be tried.
# - agent-guides' mac.sh (MAC_SH) and ssh to the VM as macos27 (MAC_HOST), as
#   Scripts/screenshots.sh does. The VM needs the internet, for the two test hosts.
# - Swift on this Mac, to build the test app in Scripts/escape-test.
# - Nobody using the VM's screen meanwhile: the script clicks in it.
# - A VM kept for testing. The switches it flips are the Watched row's, which act on
#   every watched app in the VM, not only the test app: the others are blocked and
#   limited along with it, have their Other access reset, and come out with Local
#   Network and the internet allowed, whatever they had before.
#
# It clicks the summary row's switches by position, since macOS doesn't offer the panel's
# switches to accessibility there, and checks each click against Revoke's own lists. If
# the panel's layout changes, the offsets in `column` and `header_y` are what to update.
#
# The VM is left as it was: the test app and the two extra subnets are removed, the
# blocks and limits the run set are lifted, the test app's link is given back, Revoke's
# settings are put back, and the VM is shut down if this script started it.
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
test_scheme=revoke-escape-test
# Addresses for the VM's own interface, in subnets that only being on-link makes local:
# carrier-grade NAT, and IPv6's range for documentation, which is global as far as the
# filter can tell.
extra_v4=100.64.77.1
extra_v6=2001:db8:77::1
# The shortest time limit Revoke offers, and how long past it the run waits.
limit_minutes=15
# A DNS server out on the internet, for checking a limited app can still look names up.
public_dns=1.1.1.1
limit_grace=120
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

saved_settings=/tmp/revoke-escape-settings.plist
iface=
dns_service=
dns_before=
cleanup() {
	local rc=$?
	trap - EXIT INT TERM
	print "==> Putting the VM back"
	guest "pkill -f 'caffeinate -d -u -t $awake_seconds'" >/dev/null 2>&1 || true
	# The time limit first, with Revoke quit, so it can't take anything back meanwhile.
	mac quit Revoke >/dev/null 2>&1 || true
	guest "pkill -x Revoke; sleep 1; defaults delete $defaults_domain limitStart; defaults delete $defaults_domain limitMinutes; defaults delete $defaults_domain revokeAfterLimit" >/dev/null 2>&1 || true
	# Lift whatever the run left, through the panel like everything else, which needs
	# Revoke running and the test app still there.
	guest '(nohup open /Applications/Revoke.app >/dev/null 2>&1 &)' >/dev/null 2>&1 || true
	sleep 6
	# A switch that's on for only some apps goes off at the first click and on at the
	# second, and a click can miss, so each list gets a few tries.
	local pair try
	for pair in localNetworkBlocked:local-network internetLimited:internet linksBlocked:links; do
		for try in 1 2 3; do
			[[ $(listed ${pair%%:*}) == yes ]] || break
			allow_local_network_question
			panel_open 2>/dev/null && click_header ${pair##*:} || true
			guest "osascript -e 'tell application \"System Settings\" to quit'" >/dev/null 2>&1 || true
		done
		[[ $(listed ${pair%%:*}) == yes ]] && print "  couldn't lift ${pair##*:} for the test app; lift it in Revoke's panel in the VM"
	done
	mac key esc >/dev/null 2>&1 || true
	guest "osascript -e 'tell application \"System Settings\" to quit'" >/dev/null 2>&1 || true
	mac quit Revoke >/dev/null 2>&1 || true
	sleep 1
	# What the test app saw, kept when something failed, for working out why.
	if (( rc != 0 || failures > 0 )); then
		mkdir -p build
		guest "cat $log.curl 2>/dev/null" > build/escape-test-curl.log 2>/dev/null || true
		guest "cat $log 2>/dev/null" > build/escape-test-app.log 2>/dev/null || true
		guest "/usr/bin/log show --last 45m --style compact --predicate 'subsystem BEGINSWITH \"dev.benjweaver.Revoke\"' 2>/dev/null" > build/escape-test-revoke.log 2>/dev/null || true
		print "  kept the test app's logs and Revoke's in build/escape-test-*.log"
	fi
	guest "pkill -x EscapeTest; rm -rf $test_app $log $log.orphan $log.links $log.curl /tmp/revoke-escape-app.zip /tmp/revoke-escape-test.zip /tmp/revoke-escape-answer.txt" >/dev/null 2>&1 || true
	if [[ -n $iface ]]; then
		guest "sudo ifconfig $iface -alias $extra_v4; sudo ifconfig $iface inet6 $extra_v6 -alias" >/dev/null 2>&1 || true
	fi
	if [[ -n $dns_service && -n $dns_before ]]; then
		guest "sudo networksetup -setdnsservers '$dns_service' $dns_before" >/dev/null 2>&1 || true
	fi
	# Revoke's settings as they were, the links it held for other apps included.
	guest "test -f $saved_settings && defaults import $defaults_domain $saved_settings && rm -f $saved_settings" >/dev/null 2>&1 || true
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
# The summary row's switches sit this far below the top of the panel's window, shadow
# included, while the status under the title is one line and nothing is on for now:
# the strip that lists timed access pushes the grid down, so the run only clicks once
# an allowance it asked for has ended.
header_y=193

# Clicks the summary row's switch in a column, which acts on every watched app. The
# last column is the Revoke button.
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
	allow_local_network_question
	panel_open || die "couldn't open Revoke's panel"
	click_header "$column"
	guest "osascript -e 'tell application \"System Settings\" to quit'" >/dev/null 2>&1 || true
	if [[ $(listed "$list") != $want ]]; then
		# What the screen looked like, for whoever has to work out why.
		panel_open && mac shot build/escape-test-failure.png >/dev/null 2>&1 || true
		die "clicking $column didn't change $list; has the panel's layout moved? (see column and header_y, and build/escape-test-failure.png)"
	fi
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

# MARK: - Links and dialogs

# Answers Allow if macOS is asking whether the test app may use the local network. The
# question comes when it likes, sits over the panel, and swallows the clicks meant for it.
allow_local_network_question() {
	guest "osascript -" <<EOF >/dev/null 2>&1 || true
tell application "System Events"
	if not (exists process "UserNotificationCenter") then return
	tell process "UserNotificationCenter"
		repeat with w in windows
			if (value of static text 1 of w) contains "EscapeTest" then click button "Allow" of w
		end repeat
	end tell
end tell
EOF
}

# The app macOS opens the test app's links with now.
link_handler() {
	guest "osascript -l JavaScript -" <<EOF
ObjC.import("AppKit");
var app = \$.NSWorkspace.sharedWorkspace.URLForApplicationToOpenURL(\$.NSURL.URLWithString("$test_scheme:"));
app.isNil() ? "none" : ObjC.unwrap(app.path);
EOF
}

# Whether a link reached the test app.
got_link() {
	guest "grep -qx '$1' $log.links 2>/dev/null"
}

# Opens a link for the test app, which goes to whichever app handles them, and answers
# Revoke's question by clicking a button by its name.
open_link() {
	guest "open '$1'; sleep 4
		osascript -e 'tell application \"System Events\" to tell process \"Revoke\" to click button \"$2\" of window 1' >/dev/null 2>&1
		sleep 3" || true
}

# Runs Revoke --restore-links, answers its question, and prints what it said. The
# question belongs to the command's own process, not to the Revoke in the menu bar.
restore_links() {
	guest "/Applications/Revoke.app/Contents/MacOS/Revoke --restore-links > /tmp/revoke-escape-answer.txt 2>&1 &
		pid=\$!
		sleep 4
		osascript -e 'tell application \"System Events\" to click button \"$1\" of window 1 of (first process whose unix id is '\$pid')' >/dev/null 2>&1
		sleep 6
		cat /tmp/revoke-escape-answer.txt; rm -f /tmp/revoke-escape-answer.txt" 2>/dev/null || true
}

# Empties macOS's cache of looked-up names, so the test app's next lookups have to ask
# the DNS server rather than be answered from memory.
forget_names() {
	guest "sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder" >/dev/null 2>&1 || true
	sleep 2
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
# Revoke's settings, to put back afterward. A file left by a run that was cut short
# is the older copy, and the one to keep.
guest "test -f $saved_settings || defaults export $defaults_domain $saved_settings" || die "couldn't save Revoke's settings in the VM"
[[ $(guest "defaults read $defaults_domain revokeAfterLimit 2>/dev/null") != 1 ]] || die "Revoke's time limit is on in the VM, and would revoke partway through; switch it off first"
gateway=$(guest "route -n get default 2>/dev/null | awk '/gateway/ { print \$2 }'")
[[ -n $gateway ]] || die "the VM has no default gateway to test the local network with"
guest "nc -z -G 3 $gateway 53" >/dev/null 2>&1 || die "the VM's gateway $gateway doesn't answer on port 53"
# Two more subnets on the same interface. The addresses are the VM's own, which is
# enough: the filter decides by the address a connection goes to.
iface=$(guest "route -n get default 2>/dev/null | awk '/interface/ { print \$2 }'")
guest "sudo ifconfig $iface alias $extra_v4 netmask 255.255.255.0 && sudo ifconfig $iface inet6 $extra_v6 prefixlen 64 alias" || die "couldn't add the test subnets to $iface in the VM"
sleep 4

print "==> Building the test app"
build=$(mktemp -d)
swiftc -O -warnings-as-errors Scripts/escape-test/main.swift -o "$build/EscapeTest"
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
	<key>CFBundleURLTypes</key><array><dict>
		<key>CFBundleURLName</key><string>$test_id</string>
		<key>CFBundleURLSchemes</key><array><string>$test_scheme</string></array>
	</dict></array>
</dict></plist>
EOF
codesign -f -s - -i "$test_id" "$build/EscapeTest.app" 2>/dev/null
ditto -c -k --keepParent "$build/EscapeTest.app" "$build/test.zip"
scp -q "$build/test.zip" "$host:/tmp/revoke-escape-test.zip"
rm -rf "$build"
guest "pkill -x EscapeTest; rm -rf $test_app $log $log.orphan $log.links $log.curl; ditto -x -k /tmp/revoke-escape-test.zip /Applications/ && rm -f /tmp/revoke-escape-test.zip"

print "==> Update: the latest release, then this build over it"
read -r url sha version <<< "$(mac cask "$tap" revoke)"
mac quit Revoke >/dev/null 2>&1 || true
mac install "$url" "$sha" >/dev/null
start_revoke || die "the release's filter ($version) didn't come up; is the filter allowed in the VM?"
candidate="$(plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist") ($(plutil -extract CFBundleVersion raw "$app/Contents/Info.plist"))"
print "  from $version to $candidate"
install_app "$app"
# The watch list and the test's host are Revoke's ordinary settings, set while it's quit.
# The links Revoke holds for the VM's other apps are set aside with them, so
# --restore-links below gives back the test app's link and no one else's. macOS still
# sends those links to Revoke meanwhile, and the settings come back at the end.
guest "defaults write $defaults_domain watched -array $test_id; defaults write $defaults_domain extraInternetHosts -array $allowed_host; defaults delete $defaults_domain linksBlocked; defaults delete $defaults_domain linkOwners" || true
if start_revoke; then pass "this build's filter took over"; else fail "this build's filter didn't take over"; fi
if why=$(filter_answers 2>&1); then pass "Revoke reaches its filter after the update"; else fail "Revoke can't reach its filter after the update: $why"; fi

print "==> Before anything is blocked"
guest "open $test_app --args $gateway $allowed_host $other_host $log $extra_v4 $extra_v6"
sleep 6
allow_local_network_question
line=$(results)
for key in lan_direct lan_child lan_orphan lan_extra1 lan_extra2 net_allowed net_allowed_session net_other net_other_session net_fronted; do
	expect "$line" $key ok "the test app reaches everything ($key)"
done
(( failures == 0 )) || die "the test app can't reach its targets with nothing blocked, so the rest would prove nothing"

print "==> Local Network blocked"
set_column local-network localNetworkBlocked yes
forget_names
line=$(results)
expect "$line" lan_direct no "a connection from the app itself is dropped"
expect "$line" lan_child no "a connection from a command it runs is dropped"
expect "$line" lan_orphan no "a connection from a helper it handed to launchd is dropped"
expect "$line" lan_extra1 no "a connection to a carrier-grade NAT subnet the VM is on is dropped"
expect "$line" lan_extra2 no "a connection to a global IPv6 subnet the VM is on is dropped"
expect "$line" net_other ok "the internet is untouched"
# The VM's DNS server is its gateway, on the local network. Dropping the lookups macOS
# makes for a blocked app took the internet with them once a remembered name ran out.
expect "$line" net_allowed ok "and names still look up, though the DNS server is on the local network"
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
expect "$line" lan_extra1 ok "and it reaches the carrier-grade NAT subnet"
expect "$line" lan_extra2 ok "and the global IPv6 subnet"
# The two subnets have done their job. Left on, the IPv6 one gives the VM a global
# address with no route behind it, which the internet checks below would trip over.
guest "sudo ifconfig $iface -alias $extra_v4; sudo ifconfig $iface inet6 $extra_v6 -alias" >/dev/null 2>&1 || true

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
# The same with the DNS server out on the internet, where a limited app's lookups go
# when the Mac uses a public resolver.
dns_service=$(guest "networksetup -listnetworkserviceorder | grep -B1 'Device: $iface)' | head -1 | sed 's/^([0-9]*) //'")
if [[ -n $dns_service ]]; then
	dns_before=$(guest "networksetup -getdnsservers '$dns_service'" | tr '\n' ' ')
	[[ $dns_before == *"aren't any"* ]] && dns_before=empty
	guest "sudo networksetup -setdnsservers '$dns_service' $public_dns"
	forget_names
	line=$(results)
	guest "sudo networksetup -setdnsservers '$dns_service' $dns_before"
	forget_names
	expect "$line" net_allowed ok "names look up with the DNS server on the internet (curl)"
	expect "$line" net_allowed_session ok "names look up with the DNS server on the internet (URLSession)"
	expect "$line" net_other no "and the other host is still dropped"
else
	fail "couldn't find the VM's network service for $iface to change its DNS server"
fi

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

print "==> Everything switched off at once"
[[ $(link_handler) == $test_app ]] || die "the test app doesn't handle $test_scheme links, so the link checks would prove nothing (it's $(link_handler))"
allow_local_network_question
panel_open || die "couldn't open Revoke's panel"
click_header all-access
sleep 4
guest "osascript -e 'tell application \"System Settings\" to quit'" >/dev/null 2>&1 || true
mac key esc >/dev/null 2>&1 || true
if [[ $(listed localNetworkBlocked) == yes ]]; then pass "Local Network is blocked"; else fail "Local Network wasn't blocked"; fi
if [[ $(listed linksBlocked) == yes && $(link_handler) == /Applications/Revoke.app ]]; then
	pass "Revoke stands in for the test app's links"
else
	fail "Revoke didn't take the test app's links (they open $(link_handler))"
fi
# Each service is reset with tccutil, which fails on a name macOS doesn't know.
resets=$(guest "/usr/bin/log show --last 2m --style compact --predicate 'subsystem == \"dev.benjweaver.Revoke\" AND eventMessage CONTAINS \"tccutil reset\"' 2>/dev/null | grep -v Timestamp") || true
if [[ -z $resets ]]; then pass "every reset Revoke ran with tccutil worked"; else fail "a tccutil reset failed: $resets"; fi
# And each name on its own, since Revoke only reports the first failure.
services=($(awk '/var tccutilServices/ { on = 1 } on && /^    }/ { on = 0 } on' App/Pane.swift | grep -o '"[A-Za-z]*"' | tr -d '"' | sort -u))
(( ${#services} >= 20 )) || die "couldn't read the services Revoke resets out of App/Pane.swift (found ${#services})"
unknown=()
for service in $services; do
	guest "tccutil reset $service $test_id" >/dev/null 2>&1 || unknown+=($service)
done
if (( ${#unknown} == 0 )); then pass "macOS knows all ${#services} services Revoke resets"; else fail "tccutil doesn't know: $unknown"; fi

print "==> A link for the test app, while Revoke holds its links"
open_link "$test_scheme://kept-out" No
if got_link "$test_scheme://kept-out"; then fail "a link reached the app after No"; else pass "a link doesn't reach the app after No"; fi
open_link "$test_scheme://let-in" Yes
if got_link "$test_scheme://let-in"; then pass "a link reaches the app after Yes"; else fail "a link didn't reach the app after Yes"; fi
if got_link "$test_scheme://kept-out"; then fail "the link kept out arrived later"; fi

if [[ -z ${SKIP_TIME_LIMIT:-} ]]; then
	print "==> The time limit, at its shortest ($limit_minutes minutes)"
	set_column local-network localNetworkBlocked no
	mac quit Revoke >/dev/null 2>&1 || true
	sleep 1
	# As Settings writes them when the limit is switched on.
	guest "defaults write $defaults_domain revokeAfterLimit -bool true; defaults write $defaults_domain limitMinutes -int $limit_minutes; defaults write $defaults_domain limitStart -date \"\$(date -u '+%Y-%m-%d %H:%M:%S +0000')\""
	start_revoke || die "Revoke's filter wasn't there after relaunching"
	began=$(date +%s)
	line=$(results)
	expect "$line" lan_direct ok "the app has the local network while the limit runs"
	print "  waiting out the $limit_minutes minutes"
	sleep $(( limit_minutes * 60 - 60 - ($(date +%s) - began) ))
	if [[ $(listed localNetworkBlocked) == no ]]; then pass "the app still has it a minute before the limit"; else fail "Local Network was blocked before the limit was up"; fi
	blocked=no
	while (( $(date +%s) - began < limit_minutes * 60 + limit_grace )); do
		[[ $(listed localNetworkBlocked) == yes ]] && { blocked=yes; break; }
		sleep 10
	done
	if [[ $blocked == yes ]]; then pass "Revoke blocked Local Network when the limit was up"; else fail "Revoke didn't block Local Network within $limit_grace seconds of the limit"; fi
	line=$(results)
	expect "$line" lan_direct no "the running app loses the local network at its limit"
	if [[ $(listed linksBlocked) == yes && $(link_handler) == /Applications/Revoke.app ]]; then pass "Revoke still stands in for its links"; else fail "the links went back to the app at the limit"; fi
	mac quit Revoke >/dev/null 2>&1 || true
	sleep 1
	guest "defaults delete $defaults_domain revokeAfterLimit; defaults delete $defaults_domain limitMinutes; defaults delete $defaults_domain limitStart" >/dev/null 2>&1 || true
	start_revoke || die "Revoke's filter wasn't there after relaunching"
fi

print "==> Revoke --restore-links"
said=$(restore_links No)
if [[ $(link_handler) == /Applications/Revoke.app ]]; then pass "No leaves the links with Revoke"; else fail "the links moved after No (it said: ${said//$'\n'/ })"; fi
said=$(restore_links Yes)
if [[ $said == *"Gave back 1 link."* && $(link_handler) == $test_app ]]; then
	pass "Yes gives the link back to the app"
else
	fail "the link wasn't given back after Yes (it said: ${said//$'\n'/ }; links open $(link_handler))"
fi
if guest "pgrep -x Revoke" >/dev/null 2>&1; then fail "Revoke was left running, and would take the links again"; else pass "and Revoke has quit, so it doesn't take them again"; fi

print
if (( failures == 0 )); then
	print "escape-test.sh: everything held."
else
	print -u2 "escape-test.sh: $failures check$( (( failures == 1 )) || print s) failed."
	exit 1
fi
