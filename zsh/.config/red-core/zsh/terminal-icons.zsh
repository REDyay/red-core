# Red Core - event-driven terminal application detection

[[ -o interactive ]] || return

autoload -Uz add-zsh-hook

_redcore_terminal_notify() {
    # No desktop session / Quickshell unavailable -> do nothing.
    [[ -n "${WAYLAND_DISPLAY:-}" ]] || return 0
    (( $+commands[qs] )) || return 0

    # $PPID is the terminal emulator PID on our setup.
    #
    # Run IPC asynchronously so the shell prompt is never delayed.
    qs ipc call redcoreTerminal changed "$PPID" \
        >/dev/null 2>&1 &!
}

_redcore_terminal_preexec() {
    _redcore_terminal_notify
}

_redcore_terminal_precmd() {
    _redcore_terminal_notify
}

# Avoid duplicate hooks if this file gets sourced more than once.
add-zsh-hook -d preexec _redcore_terminal_preexec 2>/dev/null
add-zsh-hook -d precmd  _redcore_terminal_precmd  2>/dev/null

add-zsh-hook preexec _redcore_terminal_preexec
add-zsh-hook precmd  _redcore_terminal_precmd
