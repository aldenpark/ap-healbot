# HealBot

## Dependency: [FFXI Libraries](https://github.com/aldenpark/ffxi-libs)

Install the library files under `Windower/addons/libs/ffxi/` before loading HealBot.

## NEW: IPC has been added! (see below)

### Summary

By default, HealBot will monitor the party that it is in.  Commands to monitor
or ignore additional players can be found below.

### Healing behavior

HealBot considers monitored party members in the same zone for healing when
their HP is below 95%. The cure tier is selected from estimated missing HP and
the configured cure potency values; it is not a fixed HP percentage. The
default minimum is Cure III. Use `//hb mincure 1` if you want HealBot to use
Cure I when leveling. Curaga is considered when at least two injured party
members are close together by default. Healing still requires an available,
usable spell and a target in range.

When HealBot is active, it will rest to recover your own HP and MP if you are
idle, auto-engage is off, the party has been stationary for a few seconds, and
HealBot has no action to perform. While following, it stays down until the
follow target exceeds the configured distance; without follow, party movement
ends the rest. It also stands when an action is needed or your HP and MP are
full.

### Status HUD and quick options

Click HealBot's character status line to turn the addon on or off. Click
`Options [+]` to open the quick-options menu, then click a row to toggle it.
Click `Options [-]` to close the menu. The menu includes curing, Curaga, status
removal, buffs, debuffs, spell spam, weaponskills, assist, auto-engage, follow,
and Trust handling. Set an assist or follow target with its command before
turning that feature on from the menu.

`//hb status` prints the current addon, action, assist/follow, and HUD states
in chat, including the healing mode, minimum tier, and highest available tier.

### Status removal

When status removal is enabled and your job can use the needed spell, HealBot
attempts to remove detected effects using these spells:

| Spell | Effects |
| --- | --- |
| Cure | Lullaby |
| Blindna | Blindness |
| Cursna | Curse, Doom |
| Paralyna | Paralysis |
| Poisona | Poison |
| Silena | Silence |
| Stona | Petrification |
| Viruna | Disease, Plague |
| Erase | Weight, Accuracy Down, Addle, AGI Down, Attack Down, Bind, Bio, Burn, Choke, CHR Down, Defense Down, DEX Down, Dia, Drown, Elegy, Evasion Down, Frost, Inhibit TP, INT Down, Magic Acc. Down, Magic Atk. Down, Magic Def. Down, Magic Evasion Down, Max HP Down, Max MP Down, Max TP Down, MND Down, Nocturne, Rasp, Requiem, Shock, Slow, STR Down, VIT Down |

The detected effect must be recognized by HealBot's packet and debuff data.

Buffs gained via job abilities are now supported, but have not yet been tested
extensively.  Composure has been confirmed to work.  With the addition of job
ability support comes support for prioritization (since, for example, Composure
should be used before other buffs are applied).

Detection of whether the local healer is able to act has been improved for when
debuffs such as sleep or petrify are active, so that now it should not try to
spam spells while unable to act.  This is apparent by the text box in the top-
left corner of the screen displaying the message 'Player is disabled'.

Bard songs are officially unsupported at this time.  YMMV - it cannot handle the
fact that there is no notification given when one song overwrites another, or
maintaining multiple buffs that have the same name.  That being said, if you
only want to maintain 2-3 songs without using a dummy song, it may work.  I have
an idea about how to support BRD songs, so that should be coming soon.

Also coming soon is the ability to cast offensive spells on an assist target's
target.  

--------------------------------------------------------------------------------

### IPC (Inter-Process Communication)

HealBot now supports IPC between multiple instances of Windower running on the
same computer when both characters have HealBot loaded!  This means that HealBot
will now be even better at detecting the buffs/debuffs that are active for
characters on the same computer!

Only the healer's HealBot needs to be on - the non-healer just needs to have
HealBot loaded to be able to tell the healer's instance about its active buffs
and debuffs.

All Windower instances participating in IPC must use the updated HealBot. IPC
messages now use a fixed buff-sync format; older Lua-serialized messages are
ignored.


### Settings

If you have the shortcuts addon installed, your aliases.xml file from that addon
will be loaded, and those aliases will be available for use when specifying
buffs.

You can edit/add/remove buff lists that can be invoked with the
`//hb bufflist listName targetName` command in data/buffLists.xml.  The order of
buffs within the list does not affect the order in which they will be cast.
Follow the syntax of existing sets when adding/editing your own.

You can modify the priority with which other players will be attended to by
editing data/priorities.xml.  Note that detection of players' jobs is not
perfect at the moment, so it is better to specify individual players' priorities
by name.  Lower numbers represent higher priority.  Follow the syntax of
existing sets when adding/editing your own.

Monster abilities that do not display what debuffs they cause are specified in
mabil_debuffs.xml.  This list is woefully incomplete, but I plan on vastly
expanding it in the near future.  If you decide to add any, I would greatly
appreciate it if you would share what you have added.  If you add something, and
it isn't detected, please notify me, and I will attempt to make sure that it can
be detected in the future.

Place the healBot folder in .../Windower/addons/

* To load healBot: `//lua load healbot`
* To unload healBot: `//hb unload`
* To reload healBot: `//hb reload`

### Command List
**Note:** Shortcut commands below are highlighted in **bold** (e.g., **f** is a shortcut for **f**ollow)

| Command | Action |
| --- | --- |
| //hb on | Activate |
| //hb off | Deactivate (note: follow will remain active) |
| //hb refresh | Reload settings xmls in the data folder |
| //hb status | Displays addon, action, assist/follow, and HUD states in chat |
| //hb mincure # | Set the minimum cure tier to # (default is 3) |
| //hb spam use spellName | Select the spell/action to use for spell spam |
| //hb spam on/off | Enable or disable spell spam |
| //hb disable actionType | Disable curing, Curaga, status removal, buffs, debuffs, spell spam, or weaponskills |
| //hb enable actionType | Re-enable a disabled action type |
| //hb reset | Reset buff & debuff monitors |
| //hb reset buffs | Reset buff monitors |
| //hb reset debuffs | Reset debuff monitors |
| //hb buff charName spellName | Maintain the buff spellName on player charName |
| //hb buff <t> spellName | Maintain the buff spellName on current target |
| //hb cancelbuff charName spellName | Stop maintaining the buff spellName on player charName |
| //hb cancelbuff <t> spellName | Stop maintaining the buff spellName on current target |
| //hb bufflist listName charName | Maintain the buffs in the given list of buffs on player charName |
| //hb bufflist listName <t> | Maintain the buffs in the given list of buffs on current target |
| //hb **f**ollow charName | Follow player charName |
| //hb **f**ollow <t> | Follow current target |
| //hb **f**ollow off | Stop following |
| //hb **f**ollow dist # | Set the follow distance to # yalms (valid range: greater than 0 and less than 45) |
| //hb ignore charName | Ignore player charName so they won't be healed |
| //hb unignore charName | Stop ignoring player charName (note: will not watch a player that would not otherwise be watched) |
| //hb watch charName | Watch player charName so they will be healed |
| //hb unwatch charName | Stop watching player charName (note: will not ignore a player that would be otherwise watched) |
| //hb ignoretrusts on | Ignore Trust NPCs (default) |
| //hb ignoretrusts off | Heal Trust NPCs |

| Debugging commands | Action |
| --- | --- |
| //hb moveinfo on | Will display current (x,y,z) position and the amount of time spent at that location in the upper left corner. |
| //hb moveinfo off | Hides the moveInfo display |
| //hb packetinfo on | Adds to the chat log packet info about monitored players |
| //hb packetinfo off | Prevents packet info from being added to the chat log |
