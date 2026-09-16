# zsh-startup-profiler

Finds out why a new terminal tab is slow.

Times `.zshrc` as a whole and then every `precmd` hook individually, for one
shell startup, and writes the result to a log.

Startup cost often is not in `.zshrc` at all — it is in a hook that runs after `.zshrc` finishes,
while the prompt is already on screen and the shell is not yet accepting input. Timing
`.zshrc` alone cannot see that; `zsh -i -c exit` never renders a prompt, so it cannot either.

Example output for a shell that took 10 seconds to become usable:

```
2026-09-16 01:51:22  tty=ttys019  term=iTerm.app
  .zshrc                                 197.9 ms
  _p9k_do_nothing                          0.0 ms  (t+209)
  _p9k_precmd_first                        0.1 ms  (t+209)
  _antigen_compinit                       19.6 ms  (t+229)
  omz_termsupport_precmd                   0.1 ms  (t+229)
  _zsh_highlight_main__precmd_hook         0.1 ms  (t+229)
  _p9k_precmd                           9752.4 ms  (t+9981)
  iterm2_precmd                           15.3 ms  (t+9996)
  _zsh_autosuggest_start                  13.3 ms  (t+10009)
  TOTAL to first prompt                10009.7 ms
  cwd=/Users/you/some/repo
```

## Install

### 1. The plugin

antigen:

```zsh
antigen bundle JamesBalazs/zsh-startup-profiler
```

oh-my-zsh — clone into your custom plugins directory, then add it to `plugins`:

```zsh
git clone https://github.com/JamesBalazs/zsh-startup-profiler \
  ${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/zsh-startup-profiler
```

```zsh
plugins=(... zsh-startup-profiler)
```

Manual — source it from `.zshrc`, ideally near the end:

```zsh
source /path/to/zsh-startup-profiler/zsh-startup-profiler.plugin.zsh
```

### 2. The `.zshenv` line

Add this to `~/.zshenv`:

```zsh
zmodload zsh/datetime && ZSH_PROFILE_T0=$EPOCHREALTIME
```

It costs a few microseconds and does nothing unless profiling is switched on.

## Why the `.zshenv` line

A plugin cannot time what ran before the plugin loaded.

Plugin managers source bundles partway through `.zshrc` — with antigen, at
`antigen apply`. Everything above that point (`compinit`, SDK completion
scripts, the plugin manager's own startup) is already spent by then, and that is
frequently where the time actually goes. `.zshenv` is read before `.zshrc` for
every shell, so it is the earliest point available to any user code.

Without the line, the plugin falls back to its own load time and marks the
session `[no-zshenv-t0]` in the report, so partial numbers are never mistaken
for complete ones.

## Use

Profiling is opt-in — an unprofiled shell gets four function definitions and
nothing else. No hooks are installed, and no shell you are not actively
measuring is touched.

```zsh
zsp-enable     # profile newly started shells
zsp-disable    # stop
zsp-status     # is it on, is this shell instrumented, where is the log
```

`zsp-enable` writes a flag file and takes effect for shells started afterwards —
not the one you typed it in. Open a new tab, ideally a slow one, then:

```zsh
zsp-report     # last 5 sessions
zsp-report 20  # last 20
```

For a single one-off measurement without the flag file, start a shell with
`ZSH_PROFILE=1` in its environment.

## Where the logs live

```
~/.local/state/zsh-startup-profiler/startup.log
```

Or `$XDG_STATE_HOME/zsh-startup-profiler/startup.log` if `XDG_STATE_HOME` is
set. `zsp-status` prints the resolved path. Override with `ZSH_PROFILE_LOG`.

The flag file that `zsp-enable` creates:

```
~/.config/zsh-startup-profiler/enabled
```

Or `$XDG_CONFIG_HOME/zsh-startup-profiler/enabled`. Override with
`ZSH_PROFILE_FLAG`.

The log is appended to, one block per profiled shell, and is plain
tab-separated text — `SESSION`, `ZSHRC`, `HOOK`, `TOTAL` records. Delete it
whenever; it is recreated as needed.

## How it works

`.zshrc` has finished by the time any `precmd` hook runs, so the profiler's own
first hook records the end of `.zshrc`.

Wrapping every hook at plugin load would miss any hook registered later in
`.zshrc`. With a typical config, that means the terminal integration and
autosuggestions hooks, which register after the plugin manager runs.

Instead the profiler registers one hook first, and wraps the others from inside
it on the first prompt. zsh resolves hooks by name at call time, so hooks
already queued later in the array still pick up the wrapper.

Everything is removed at `zle-line-init`, when the line editor becomes ready to
accept input. That is both the honest definition of "time to first prompt" and
the point after which the wrappers are no longer wanted: powerlevel10k reorders
`precmd_functions` on every prompt, and tearing down at the start of the second
prompt would let a reordered hook slip into the log.

## Limitations

**`$pipestatus` is not preserved.** Wrapping a hook means running code before
it, and powerlevel10k reads `$?` and `$pipestatus` as its first two statements.
`$?` is restored exactly, so exit codes in your prompt stay correct. There is no
way to restore `$pipestatus`, so it collapses to a single element. If you have a
prompt segment that displays per-stage pipeline status, it will be wrong for the
first prompt of a profiled shell. Nothing else is affected, and nothing is
affected at all in an unprofiled shell.

**One prompt per shell.** Only the first prompt is measured. That is the one
that determines how long a new tab takes to become usable.

**Hook time is inclusive.** A hook that spawns something synchronously is
charged for it. Work a hook defers to the background is not.
