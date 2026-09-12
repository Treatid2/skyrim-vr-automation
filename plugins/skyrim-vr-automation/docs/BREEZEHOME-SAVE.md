# Maintained Breezehome save

Until the automated New Game path is robust enough to be the default, the
maintained base MO2 profile provides a known-good save inside Whiterun
Breezehome.

One verified world-entry save is sufficient. It need not provide every desired
test location: after the game has loaded through this baseline, guarded `coc`
and `cow` commands may request alternate cells and worldspaces. The installer
or list maintainer must live-load the save in the maintained source profile
before recording or refreshing its fixture hashes.

The portable fixture ID is `breezehome-interior`. Create a task profile with
`-SavePolicy VerifiedFixture -FixtureId breezehome-interior` when the task is
authorized to load this exact baseline. The `create` result reports the current
exact save selector as `data.saveFixture.loadName` and its human-readable
location as `data.saveFixture.location`. Use those returned values rather than
hard-coding a save filename, because maintaining the base profile may replace
the underlying save.

Every newly created task profile receives a verified copy of the complete
`saves` tree from `defaults.testProfileSource`, regardless of `SavePolicy`.
`MainMenuOnly` still forbids loading any save, and `FreshGame` still requires a
genuine New Game path; copying saves does not broaden either authorization.

Before creating a `VerifiedFixture` task workspace, run `fixture-status`. A result of
`fixture-valid` confirms that the declared Breezehome `.ess` and matching
co-save exist and match their recorded hashes. If it is stale, repair the
maintained base profile or use the guarded `refresh-fixture` workflow before
creating the task profile. Only `VerifiedFixture` creation is blocked otherwise;
`MainMenuOnly` and `FreshGame` do not depend on this declaration.

This integrity verification belongs to the maintained source at clone time. It
does not by itself prove a successful load under a particular game, plugin, or
HMD runtime. Once a task changes its profile, mods, or saves, the toolkit cannot
guarantee that its retained save remains loadable. A later `resume` therefore
preserves that workspace as-is; it does not overwrite it with the primary
profile or silently renew the guarantee.
