# authcheck.tcl -- Maxima proves to its frontend that it is Maxima.
#
# Plays xmaxima's part with xmaxima's own Authenticate.tcl and
# InterruptChannel.tcl: listens on a port, lets three impostors connect to it
# first -- one sending a wrong secret followed by a Tcl command for xmaxima to
# evaluate, one sending what an older Maxima sends, one sending nothing, one
# sending a line that never ends --
# then starts Maxima with -s <port> and a secret in MAXIMA_AUTH_CODE. Checks
# that the impostors are refused and Maxima isn't, that the line with the
# secret doesn't reach the console filter, that the session computes 1+41,
# and, on a Lisp with threads, that the interrupt channel still opens.
# Finally checks that a Maxima started without MAXIMA_AUTH_CODE still starts
# its connection with "pid=", as it always did.
#
# Usage: tclsh authcheck.tcl <maxima-local> <lisp> <Tkmaxima-directory>
#
# Prints "authcheck: PASS" or "authcheck: FAIL" with a reason (exit 1).

lassign $argv maxima lisp tkmaximaDir
source [file join $tkmaximaDir InterruptChannel.tcl]
source [file join $tkmaximaDir Authenticate.tcl]

set key test
set output ""
set mainSocket ""
set pids {}
set deadline [expr {[clock seconds] + 120}]

proc finish { status message } {
    global mainSocket
    puts "authcheck: $status"
    if {$message ne ""} {
        puts $message
    }
    puts "--- What reached the console filter ---"
    puts $::output
    icClose $::key
    authForget $::key
    if {$mainSocket ne ""} {
        catch {puts $mainSocket "quit();"; flush $mainSocket}
        catch {close $mainSocket}
    }
    foreach pid $::pids {
        catch {exec kill $pid}
    }
    exit [dict get {PASS 0 FAIL 1} $status]
}

# Waits until CONDITION, a Tcl expression, is true, or fails after the
# deadline.
proc waitUntil { condition what } {
    while {![uplevel #0 [list expr $condition]]} {
        if {[clock seconds] > $::deadline} {
            finish FAIL "Timed out waiting for $what."
        }
        after 50 {set ::tick 1}
        vwait ::tick
    }
}

proc accepted { sock } {
    set ::mainSocket $sock
    fileevent $sock readable [list consoleFilter $sock]
}

# Stands in for xmaxima's filters: everything it gets, xmaxima would act on.
proc consoleFilter { sock } {
    append ::output [read $sock]
    if {[eof $sock]} {
        finish FAIL "Maxima closed the connection."
    }
}

proc send { text } {
    puts $::mainSocket $text
    flush $::mainSocket
}

# An impostor's end of its connection. Records when the frontend closes it.
proc impostor { name firstWords } {
    set sock [socket 127.0.0.1 $::port]
    fconfigure $sock -blocking 0 -translation lf
    if {$firstWords ne ""} {
        puts -nonewline $sock $firstWords
        flush $sock
    }
    set ::closed($name) 0
    fileevent $sock readable [list impostorEvent $name $sock]
}

proc impostorEvent { name sock } {
    if {[catch {read $sock}] || [catch {eof $sock} atEof] || $atEof} {
        set ::closed($name) 1
        catch {close $sock}
    }
}

set server [socket -server [list apply {{sock host port} {
    authCandidate $::key $sock
}}] -myaddr 127.0.0.1 0]
set port [lindex [fconfigure $server -sockname] 2]

set token [icNewToken]
authExpect $key $token accepted
set channelToken [icNewToken]
icExpect $key $channelToken {set ::channelOpen 1}

impostor wrongSecret "<wxxml-key>[icNewToken]</wxxml-key>\n\032\031tcl: set ::pwned 1\n"
impostor oldMaxima "pid=1\n"
impostor silent ""
impostor flood [string repeat x 10000]
waitUntil {$::closed(wrongSecret) && $::closed(oldMaxima) && $::closed(flood)} \
    "the frontend to refuse the impostors"
if {[info exists ::pwned]} {
    finish FAIL "An impostor got its Tcl command evaluated."
}
if {![authWasRejected $key]} {
    finish FAIL "authWasRejected doesn't report the refused impostors."
}
if {[authIsAccepted $key]} {
    finish FAIL "An impostor was taken for Maxima."
}

set env(MAXIMA_AUTH_CODE) $token
set env(MAXIMA_INTERRUPT_TOKEN) $channelToken
lappend pids [exec $maxima --no-init -q --lisp=$lisp -s $port \
                  >@ stdout 2>@ stderr &]

waitUntil {[authIsAccepted $::key]} "Maxima to authenticate"
waitUntil {[regexp {\(%i1\)} $::output]} "Maxima's first prompt"
if {![string match "pid=*" $output]} {
    finish FAIL "The console filter didn't start with Maxima's pid line."
}
if {[string first $token $output] >= 0} {
    finish FAIL "The secret reached the console filter."
}
waitUntil {$::closed(silent)} \
    "the frontend to close the impostor that never spoke"

set from [string length $output]
send {1+41;}
waitUntil {[regexp -start $from {42} $::output]} "the result of 1+41"

# The interrupt channel arrives at the same port while the main connection
# is still being checked; it must not be taken for an impostor.
set from [string length $output]
send {:lisp (format t "channel-available=~a~%" (maxima::interrupt-channel-available-p))}
waitUntil {[regexp -start $from {channel-available=(T|NIL)} $::output]} \
    "the answer whether threads exist"
if {[regexp -start $from {channel-available=T} $output]} {
    waitUntil {[icIsOpen $::key]} "Maxima's interrupt channel"
}

# Without MAXIMA_AUTH_CODE, Maxima starts its connection as it always did.
unset env(MAXIMA_AUTH_CODE)
unset env(MAXIMA_INTERRUPT_TOKEN)
set plainServer [socket -server [list apply {{sock host port} {
    fconfigure $sock -blocking 1 -translation lf -encoding utf-8
    set ::plainFirstLine [gets $sock]
    close $sock
}}] -myaddr 127.0.0.1 0]
set plainPort [lindex [fconfigure $plainServer -sockname] 2]
lappend pids [exec $maxima --no-init -q --lisp=$lisp -s $plainPort \
                  >@ stdout 2>@ stderr &]
waitUntil {[info exists ::plainFirstLine]} \
    "the first line of a Maxima without MAXIMA_AUTH_CODE"
if {![string match "pid=*" $plainFirstLine]} {
    finish FAIL "Without MAXIMA_AUTH_CODE the first line is '$plainFirstLine'."
}

finish PASS ""
