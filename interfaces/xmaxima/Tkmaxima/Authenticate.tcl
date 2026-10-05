############################################################
# Authenticate.tcl                                         #
# For distribution under GNU public License.  See COPYING. #
#                                                          #
############################################################
#
# Telling the Maxima xmaxima started from anybody else who connects.
#
# xmaxima listens on a port and starts Maxima with -s <port>. Any program on
# this machine can connect to that port, and whoever xmaxima takes for Maxima
# receives everything the user types and has xmaxima evaluate the Tcl code it
# sends after \032\031tcl: -- so the first connection is not necessarily
# Maxima's.
#
# So xmaxima passes Maxima a random secret in the environment variable
# MAXIMA_AUTH_CODE, and Maxima's first line is
# "<wxxml-key><secret></wxxml-key>", the line wxMaxima checks, too (see
# "Authenticating the connection" in src/server.lisp). A process's
# environment can only be read by its own user and the administrator.
# xmaxima reads nothing else from a connection until that line has arrived,
# and closes a connection whose first line is anything else.
#
# Maxima's interrupt channel (InterruptChannel.tcl) arrives at the same port
# and can arrive before the main connection's first line has been read, so
# every connection goes through authCandidate, which hands a first line that
# isn't the main connection's to the channel's handshake.
#
# Like InterruptChannel.tcl, this needs neither Tk nor the rest of xmaxima.
# All state lives in the array ::authState, indexed by a key the caller
# chooses (xmaxima uses the console's text widget).

# authExpect --
#
#   Starts waiting for the main connection of the Maxima belonging to KEY,
#   which will authenticate itself with TOKEN. Forgets what KEY expected
#   before. Once it has, ONACCEPT is evaluated with the connection's socket
#   appended.
#
proc authExpect { key token onAccept } {
    authForget $key
    set ::authState($key,token) $token
    set ::authState($key,onAccept) $onAccept
    set ::authState($key,pending) {}
}

# authCandidate --
#
#   Hands SOCK, a connection that just arrived at KEY's port, to the
#   handshake.
#
proc authCandidate { key sock } {
    if {![info exists ::authState($key,token)]} {
        catch {close $sock}
        return
    }
    lappend ::authState($key,pending) $sock
    fconfigure $sock -blocking 0 -translation lf -encoding utf-8
    fileevent $sock readable [list authHandshake $key $sock]
}

proc authHandshake { key sock } {
    if {[catch {gets $sock line} len] || $len < 0} {
        if {[catch {eof $sock} atEof] || $atEof || \
                [catch {chan pending input $sock} buffered] || \
                $buffered > 4096} {
            # Closed, or a first line far longer than Maxima's would be
            # that would otherwise pile up in memory.
            authDrop $key $sock
            catch {close $sock}
        }
        # Otherwise only part of the line has arrived yet.
        return
    }
    authDrop $key $sock
    fileevent $sock readable {}
    if {![info exists ::authState($key,token)]} {
        catch {close $sock}
        return
    }
    # Some Lisps end their lines with CRLF on MS Windows.
    set line [string trimright $line \r]
    if {![authIsAccepted $key] && \
            $line eq "<wxxml-key>$::authState($key,token)</wxxml-key>"} {
        set ::authState($key,accepted) 1
        # The other connections still waiting can't be Maxima's.
        foreach other $::authState($key,pending) {
            catch {close $other}
        }
        set ::authState($key,pending) {}
        uplevel #0 [linsert $::authState($key,onAccept) end $sock]
        return
    }
    if {[icOffer $key $sock $line]} {
        return
    }
    if {![authIsAccepted $key]} {
        set ::authState($key,rejected) 1
    }
    catch {close $sock}
}

proc authDrop { key sock } {
    if {[info exists ::authState($key,pending)]} {
        set i [lsearch -exact $::authState($key,pending) $sock]
        if {$i >= 0} {
            set ::authState($key,pending) \
                [lreplace $::authState($key,pending) $i $i]
        }
    }
}

# authIsAccepted --
#
#   True once KEY's Maxima has authenticated its main connection.
#
proc authIsAccepted { key } {
    return [info exists ::authState($key,accepted)]
}

# authWasRejected --
#
#   True if a connection to KEY's port was closed because it didn't
#   authenticate, before Maxima's own did -- for example because Maxima is
#   an older version that doesn't send the line.
#
proc authWasRejected { key } {
    return [info exists ::authState($key,rejected)]
}

# authForget --
#
#   Stops expecting a connection for KEY and closes the ones that haven't
#   authenticated yet. The accepted connection is the caller's.
#
proc authForget { key } {
    if {[info exists ::authState($key,pending)]} {
        foreach sock $::authState($key,pending) {
            catch {close $sock}
        }
    }
    array unset ::authState $key,*
}
