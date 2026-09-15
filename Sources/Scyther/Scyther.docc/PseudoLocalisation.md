# Pseudo-localisation

Find out whether an interface survives translation, before a single string is translated.

@Metadata {
    @PageColor(green)
}

## Overview

Most localisation bugs are not translation bugs. They are layout bugs that only appear once the
copy changes: a label sized against English that clips at 130%, a chevron pinned to the trailing
edge that ends up on the wrong side in Arabic, a string somebody forgot to put through
`NSLocalizedString` at all. All three are findable long before a translator is briefed, by
rendering the app with copy that *behaves* like a translation without *being* one.

**UI/UX → Pseudo-localisation** offers four modes, each a switch, each off by default, and all
freely combinable — plus a fifth switch that is a setting about them rather than a mode of its own:

| Mode | What it does | What it finds |
| --- | --- | --- |
| Accented | `Hello` becomes `Ĥéļļö` | Text still in plain ASCII was never localised |
| Lengthened | `[Hello··]`, about 135% of the original | Clipping and truncation |
| Right to Left | Mirrors the layout | Hard-coded leading/trailing assumptions |
| Show Keys | Renders `Selected %lld items` instead of `Selected 5 items` | Which catalog entry produced a piece of copy |

The bracketing in Lengthened is the point of it: a label that has lost its closing `]` was
truncated, which is far easier to see in a screenshot than judging whether some accented text
looks a few characters short.

That is also why **Show Boundaries** — the fifth switch, and the only one that ships **on** —
exists at all. The padding dots say a string grew; only the closing bracket says whether the end of
it was cut off. Switching it off keeps the expansion and drops the delimiters, giving their two
characters back to the padding so both forms grow a string by the same amount. It transforms
nothing itself, so with every text mode off it does nothing whichever way it is set, and it reads
as on when nothing has been stored for it — an install that predates it keeps the brackets it has
always had. See ``PseudoLocalizationMode/showsBoundaries``.

## What it can reach, and what it cannot

This is the part worth reading before relying on the feature.

Scyther's own interface is always transformed. Every string in the package goes through
``localized(_:comment:)``, so the transform sits directly in the resolution path and nothing can
slip past it.

Your app is a different question, and the answer depends on how your code loads its strings:

- **`NSLocalizedString` is reached.** It is a thin wrapper over
  `-[NSBundle localizedStringForKey:value:table:]`, an Objective-C method, and Scyther swizzles it
  while a text mode is on. That covers UIKit apps, storyboard and XIB strings, and any Swift code
  written the traditional way.
- **`String(localized:)` is not reached.** Neither is `LocalizedStringResource`, and neither is
  SwiftUI's `Text("Some key")`.

The second point was measured rather than assumed. With that `NSBundle` method hooked, resolving a
string through each of those paths — including rendering a `Text` all the way to a bitmap with
`ImageRenderer`, which succeeded — never once reached the hook. Foundation's Swift-native
localisation path does not descend into `NSBundle` at all, and no other selector on the class sees
those calls either, the private `localizedStringForKey:value:table:localizations:` included. There
is no hookable funnel for them.

So, plainly: **on a modern SwiftUI app whose copy is written as `Text("…")`, the three text modes
pseudo-localise Scyther's own interface and nothing else.** That still shows what
pseudo-localisation looks like, and Scyther's menu is a real, fully localised SwiftUI app to look
at it on — but it is a demonstration, not a test of your screens. On a UIKit or
`NSLocalizedString`-based app it is a test of your screens.

Right to Left is a different mechanism, and it is a **next-launch setting on every surface**. It
changes no text, so it does not care how your copy is loaded — and nothing changes in the session
where the switch is flicked:

| Surface | When it mirrors | Checked on a device |
| --- | --- | --- |
| The host app's UIKit views | On the next launch | yes |
| The host app's SwiftUI views | On the next launch | yes |
| The Scyther menu, and every page reached from it | On the next launch | yes |

Switching the mode off unwinds the same way, on the launch after it is switched off.

The third column is there because this mode's reach was claimed wrongly three times on the strength
of how a mechanism *ought* to behave, and each time a device disagreed. These rows were checked the
only way that settles it: relaunched with the keys present, and relaunched with them absent.

Because nothing takes effect until then, the toggle raises the same **Relaunch required** alert
``LanguageView`` raises, with **Later** and **Quit App**.

An earlier version of this mode reached the host app through `UIView.appearance()` instead, and
that is worth recording so it is not tried again. The appearance proxy stamps a view once, as the
view joins a window, and never revisits it, so switching the mode off could not undo the views it
had already stamped. Worse, a leftover stamp does not merely mirror a layout: it disagrees with the
SwiftUI environment around it, and UIKit answers by mirroring content SwiftUI has already laid out
the other way, which draws text backwards — `Fonts` as `stnoF`, measured on a device across three
attempts to clean up after it. It also never reached a SwiftUI host app at all. The defaults keys
do what it was reaching for, at the only moment it can be done properly, and nothing is stamped any
more.

The mechanism is one thing rather than two, which is the point.
``PseudoLocalizationLayout/applyToHostApp(rightToLeft:isTestCase:isAppStore:systemDefaults:)``
writes `AppleTextDirection` and `NSForceRightToLeftWritingDirection` into the host app's standard
`UserDefaults`: the two keys Xcode's own **Right to Left Pseudolanguage** scheme option passes on
the command line, resolved before any view exists, reaching UIKit and SwiftUI alike — Scyther's own
menu among them, since it is in the same process. Writing into the host's defaults domain is the
same move ``LanguageOverride`` already makes with `AppleLanguages`.

Switching off removes both keys rather than writing `false`, so the app returns to the state it was
in before Scyther was asked. See that function for why an App Store build refuses to set the keys
and still clears them.

Scyther's interface no longer mirrors the moment the switch moves. It used to, through
`\.layoutDirection` installed in ``MenuView`` and ``PseudoLocalizationView``, and that was the last
mid-session effect this mode had — see ``PseudoLocalizationLayout`` for the four rounds of evidence
that any mid-session effect ends up disagreeing with something and reversing text. The environment
value is still installed from the *language* override, which has no launch-time half to disagree
with: see ``LanguageOverride/layoutDirection(forLanguage:)``.

It is installed with `transformEnvironment`, and only when a language override is actually set —
``LanguageOverride/menuLayoutDirection`` returns `nil` otherwise. Pinning it unconditionally to the
device language's direction beat the launch keys, so a relaunch with the mode on mirrored the host
app and left Scyther's menu, alone on screen, unmirrored. Seen on device.

The toggle's own subtitle carries all of this, not just these docs. A developer looking at a switch
that says "forces right-to-left layout" and seeing nothing move has been told something false, and
no amount of accurate prose elsewhere repairs that.

## Safety

The rule behind all of this: **never produce broken text that is not a localisation problem.** A
dead link or a plural that stops expanding is not a finding, it is a defect the developer will
spend an afternoon chasing in their own code, and a diagnostic tool that manufactures those is
worse than no tool.

- Every mode is off by default and persisted under `Scyther_pseudo_localization_*` in
  `UserDefaults.scyther`. ``PseudoLocalization/showsBoundaries`` is the one switch that reads as on
  with nothing stored, and ``PseudoLocalization/reset()`` restores it to on rather than clearing
  it, because that is its shipped state.
- The switches are read once and held in memory rather than read from `UserDefaults` per string.
  `localized(_:comment:)` asks whether a text mode is on for every piece of copy Scyther resolves,
  which is about 1,500 questions for one render of the main menu, and in the Simulator each defaults
  read costs about 2 ms. ``PseudoLocalizationModeCache`` invalidates on this feature's own setters
  and on any other `UserDefaults` write in the process, so what is cached can never disagree with
  what is persisted — including after the UserDefaults browser's **Reset all Scyther settings**,
  which removes the whole suite rather than writing a key.
- Show Boundaries changes how another mode renders and nothing else. It is deliberately absent from
  ``PseudoLocalizationMode/textAffecting``, so it can never install the hook into the host app's
  string loading on its own.
- The swizzle is installed only while a text mode is on, and removed the moment the last one is
  switched off. An app that never opens the page never has its string loading touched.
- Only `Bundle.main` is transformed, and within it only the default `Localizable` table. UIKit's
  own "Cancel" and "Done" resolve normally, and so does a table the app named on purpose — teams
  routinely keep analytics identifiers, feature-flag names and segment keys in one. The trade is
  one-directional and deliberate: copy in a named table is missed, which costs coverage, whereas
  transforming an identifier table would change what the app *does*.
- `.stringsdict` plurals are returned untouched, as the exact object Foundation produced. See
  ``PseudoLocalizationTransform/carriesPluralConfiguration(_:)`` for why neither the variable name
  nor the attached configuration can be carried through a transform.
- Accenting preserves everything that is not copy: format specifiers, `.stringsdict` variables,
  brace placeholders, and URLs and email addresses. See
  ``PseudoLocalizationTransform/accentuate(_:)``.
- Neither the swizzle nor the forced layout direction is installed on an App Store build or under
  XCTest. Each carries that guard itself rather than relying on its caller, and an App Store build
  honours no persisted mode at all.

## The escape hatch

Pseudo-localising a debug menu has an obvious trap: with Show Keys and Right to Left both on, the
switch that undoes it would be a raw catalog key laid out backwards, somewhere in a list of raw
catalog keys laid out backwards.

The Pseudo-localisation page, and its row in the menu, are therefore the one part of Scyther whose
*text* is never transformed — they resolve their copy through `localizedChrome(_:comment:)`
instead. The page carries a **Sample** row so it can still show what the modes do while remaining
the one place they do not apply, and a **Turn Everything Off** button.

The exemption covers text only. After a relaunch with Right to Left on, this page is mirrored along
with everything else in the process; that is deliberate, because the text stays perfectly legible
mirrored and insulating one screen from the layout mode would misrepresent what the mode does.

The exemption is deliberately narrow. Exempting the whole menu would be safer still and would also
mean there was nothing to see.

## Known limits

- Right to Left takes effect only at launch, in both directions and on every surface including
  Scyther's own menu. The toggle raises a **Relaunch required** alert rather than leaving that to
  be discovered. Xcode's **Edit Scheme → Run → Options → App Language → Right to Left
  Pseudolanguage** does the same thing from the scheme.
- Right to Left writes two keys into the host app's standard `UserDefaults` and removes them when
  switched off. Nothing else in the app's own defaults domain is touched, and nothing at all is
  written on an App Store build or under XCTest.
- Strings the app has already resolved and cached are not revisited. A label rendered before the
  mode was switched on keeps its old text until something re-renders it.
- Show Keys recovers the catalog key by reflecting on `String.LocalizationValue`, whose layout is
  not a contract. If a future OS changes it, the mode falls back to showing the resolved English
  copy rather than failing.
- Pseudo-localised menu titles do not match what you type into the menu's search field, for the
  same reason a French menu does not match English queries. The search route back to this page
  survives on its hand-written ASCII keyword aliases, which a test pins.
- Copy kept in a named `.strings` table, and any `.stringsdict` plural, are not transformed.
- URLs, email addresses and brace placeholders are recognised by shape, not parsed. A token that
  merely looks like one is left alone; the bias is deliberately towards under-transforming, since
  a missed string costs coverage and a mangled link costs the developer an afternoon.

## Topics

### Settings

- ``PseudoLocalization``
- ``PseudoLocalizationMode``

### Transformation

- ``PseudoLocalizationTransform``
- ``PseudoLocalizationKey``

### Hooks

- ``PseudoLocalizationHostHook``
- ``PseudoLocalizationLayout``

### Interface

- ``PseudoLocalizationView``
- ``PseudoLocalizationViewModel``
