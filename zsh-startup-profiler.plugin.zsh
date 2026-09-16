# zsh-startup-profiler — times .zshrc and every precmd hook for one shell startup.
#
# Instrumentation is opt-in. When off, this file defines four helper functions
# and does nothing else, so unprofiled shells are untouched.
#
# See README.md for installation and log locations.

zmodload zsh/datetime 2>/dev/null || return

: ${ZSH_PROFILE_STATE_DIR:=${XDG_STATE_HOME:-$HOME/.local/state}/zsh-startup-profiler}
: ${ZSH_PROFILE_LOG:=$ZSH_PROFILE_STATE_DIR/startup.log}
: ${ZSH_PROFILE_FLAG:=${XDG_CONFIG_HOME:-$HOME/.config}/zsh-startup-profiler/enabled}

# The plugin loads partway through .zshrc, so it cannot time what ran before it.
# ZSH_PROFILE_T0 is set from .zshenv (see README); fall back to load time and
# mark the session partial so the report says so.
if [[ -n $ZSH_PROFILE_T0 ]]; then
  typeset -g _zsp__t0=$ZSH_PROFILE_T0 _zsp__partial=
else
  typeset -g _zsp__t0=$EPOCHREALTIME _zsp__partial='no-zshenv-t0'
fi

zsp-enable() {
  mkdir -p ${ZSH_PROFILE_FLAG:h} && : > $ZSH_PROFILE_FLAG &&
    print -r -- "profiling enabled; applies to newly started shells"
}

zsp-disable() {
  rm -f $ZSH_PROFILE_FLAG &&
    print -r -- "profiling disabled; applies to newly started shells"
}

zsp-status() {
  local on=off
  [[ $ZSH_PROFILE == 1 || -f $ZSH_PROFILE_FLAG ]] && on=on
  print -r -- "profiling:   $on"
  print -r -- "this shell:  ${${_zsp__installed:+instrumented}:-not instrumented}"
  print -r -- "t0 source:   ${${_zsp__partial:+plugin load (PARTIAL - add the .zshenv line)}:-.zshenv}"
  print -r -- "log:         $ZSH_PROFILE_LOG"
  print -r -- "flag file:   $ZSH_PROFILE_FLAG"
}

# zsp-report [N]  — show the last N sessions (default 5).
zsp-report() {
  [[ -r $ZSH_PROFILE_LOG ]] || { print -ru2 -- "no log yet at $ZSH_PROFILE_LOG"; return 1 }
  awk -F'\t' -v want="${1:-5}" '
    $1=="SESSION" { n++ }
    n { rec[n] = rec[n] $0 "\n" }
    END {
      if (!n) { print "log has no complete sessions yet"; exit }
      start = n - want + 1; if (start < 1) start = 1
      for (i = start; i <= n; i++) {
        cnt = split(rec[i], L, "\n")
        total = ""; zshrc = ""; h = 0; lastcum = 0
        delete hn; delete hms; delete hcum
        for (j = 1; j <= cnt; j++) {
          if (L[j] == "") continue
          split(L[j], F, "\t")
          if      (F[1]=="SESSION") { ts=F[2]; tty=F[4]; term=F[5]; cwd=F[6]; partial=F[7] }
          else if (F[1]=="ZSHRC")   { zshrc=F[2] }
          else if (F[1]=="TOTAL")   { total=F[2] }
          else if (F[1]=="HOOK")    { h++; hn[h]=F[2]; hms[h]=F[3]; hcum[h]=F[4]; lastcum=F[4] }
        }
        if (total == "") total = lastcum
        printf "\n%s  tty=%s  term=%s%s\n", ts, (tty==""?"?":tty), (term==""?"?":term),
               (partial=="" ? "" : "  [" partial "]")
        printf "  %-34s %9.1f ms\n", ".zshrc", zshrc
        for (j = 1; j <= h; j++)
          printf "  %-34s %9.1f ms  (t+%.0f)\n", hn[j], hms[j], hcum[j]
        printf "  %-34s %9.1f ms\n", "TOTAL to first prompt", total
        printf "  cwd=%s\n", cwd
      }
    }' $ZSH_PROFILE_LOG
}

[[ $ZSH_PROFILE == 1 || -f $ZSH_PROFILE_FLAG ]] || return 0

typeset -g _zsp__last=$EPOCHREALTIME
typeset -g _zsp__installed=1
typeset -ga _zsp__wrapped=()

# Fields are joined with tabs; print -r must not expand escapes, so build the
# separator with IFS rather than writing "\t" in the string.
_zsp__log() { local IFS=$'\t'; print -r -- "$*" >> $ZSH_PROFILE_LOG }

# Sets $? to $1 without forking. `(exit N)` would do the same but spawns a
# subshell, and this runs once per hook per profiled startup — on a machine
# where fork is expensive that overhead swamps the measurement it is taken for.
_zsp__st() { return $1 }

# Wrap one precmd hook. $? is restored before the real hook runs: powerlevel10k
# reads $? and $pipestatus as its first two statements, and a wrapper that
# clobbers them makes the prompt report the wrong exit code. _zsp__st restores
# $? exactly; $pipestatus collapses to one element, which is the single thing
# this approach cannot preserve.
_zsp__wrap() {
  local fn=$1
  (( $+functions[$fn] )) || return 1
  functions -c $fn _zsp__orig_$fn 2>/dev/null || return 1
  _zsp__wrapped+=($fn)
  eval "$fn() {
    local __st=\$?
    local __s=\$EPOCHREALTIME
    _zsp__st \$__st
    _zsp__orig_$fn \"\$@\"
    local __r=\$?
    local __e=\$EPOCHREALTIME
    (( \${+_zsp__sealed} )) || _zsp__log HOOK $fn \$(( (__e-__s)*1000 )) \$(( (__e-_zsp__t0)*1000 ))
    return \$__r
  }"
}

_zsp__uninstall() {
  local fn
  for fn in $_zsp__wrapped; do
    (( $+functions[_zsp__orig_$fn] )) && functions -c _zsp__orig_$fn $fn
    unfunction _zsp__orig_$fn 2>/dev/null
  done
  _zsp__wrapped=()
  precmd_functions=(${precmd_functions:#_zsp__bootstrap})
  unset _zsp__installed
}

# Writes TOTAL once and tears everything down. Called from zle-line-init, which
# fires when the line editor is ready to accept input — the honest definition of
# "time to first prompt". Sealing here also stops powerlevel10k's second-prompt
# hook reordering from slipping a stray wrapped hook into the log.
_zsp__seal() {
  (( ${+_zsp__sealed} )) && return
  typeset -g _zsp__sealed=1
  _zsp__log TOTAL $(( (${1:-$EPOCHREALTIME}-_zsp__t0)*1000 ))
  _zsp__uninstall
}

_zsp__line_init() {
  _zsp__seal $EPOCHREALTIME
  add-zle-hook-widget -d line-init _zsp__line_init 2>/dev/null
}

# Runs first in precmd_functions. .zshrc has finished by the time any precmd
# hook runs, so this function's own start time is the end of .zshrc.
#
# On the first prompt it wraps every other hook: zsh resolves hooks by name at
# call time, so hooks queued later in the array still pick up the wrapper. On
# the second prompt it writes TOTAL and removes all instrumentation, so the
# wrappers are live for exactly one prompt.
_zsp__bootstrap() {
  local __st=$?
  local __now=$EPOCHREALTIME
  if (( ${+_zsp__done} )); then
    _zsp__seal $__now
    _zsp__st $__st; return
  fi
  typeset -g _zsp__done=1
  mkdir -p ${ZSH_PROFILE_LOG:h} 2>/dev/null
  _zsp__log SESSION "$(strftime '%Y-%m-%d %H:%M:%S' $EPOCHSECONDS)" $$ "${TTY:t}" "${TERM_PROGRAM:-}" "$PWD" "$_zsp__partial"
  _zsp__log ZSHRC $(( (__now-_zsp__t0)*1000 ))
  local fn
  for fn in $precmd_functions; do
    [[ $fn == _zsp__* ]] || _zsp__wrap $fn
  done
  autoload -Uz add-zle-hook-widget && add-zle-hook-widget line-init _zsp__line_init
  _zsp__st $__st
}

precmd_functions=(_zsp__bootstrap ${precmd_functions:#_zsp__bootstrap})
