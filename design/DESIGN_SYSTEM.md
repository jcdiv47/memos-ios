# Memos design system

The rules every screen follows, and the code that holds them. The idea behind them is in
[`memos-ios-design.html`](memos-ios-design.html): **paper for what you wrote, glass for what you
do.** This file is about applying that idea the same way everywhere.

Everything lives in [`Memos/Design`](../Memos/Design):

| File | What it holds |
| --- | --- |
| `Tokens.swift` | `Spacing`, `Radius`, `Metrics`, `FloatingBar`, `AvatarSize`, `Stroke`, the `accentWash` and `searchHighlight` tints |
| `Typography.swift` | Type roles (`.memoBody`, `.sectionTitle`, `.metadata`, …) and symbol sizes |
| `Surfaces.swift` | `cardBackground()`, `wellBackground()`, `paperBackground()`, `cardRows()`, `readableWidth()`, `CardList`, `CardDivider` |
| `Components.swift` | `ChipStyle`, `Pill`, `SectionHeader`, `IconTile`, `Chevron`, `UnreadDot`, `WideButtonLabel`, `Avatar`, `Toast` |
| `Motion.swift` | The springs, `Press`, `ZoomTransition` |
| `CodePalette.swift`, `ActivityPalette.swift` | Syntax colours and the activity scale |
| `Assets.xcassets` | Paper, Paper 2, Card, Well, Hairline, Ink, Ink 2, Ink 3, Memos Blue, Danger, Activity 1–4 |

The widgets and the share extension compile the same token files (see `project.yml`), so the
system reaches past the app.

**Rule of thumb:** a literal number in a view is a smell. If a value isn't in the tokens, either
you want the nearest token, or the token set is missing something. Then add the token, with a
comment saying where it applies, rather than the literal. The few literals left are measured
against something outside our control, such as UIKit's 5-point text inset, and each one says so.

## Colour

| Token | Use |
| --- | --- |
| Paper | Behind every screen and sheet |
| Card | Memos, comments, link previews, grouped list rows: anything you wrote or browse |
| Well | Recessed boxes inside a card (files, voice memos, notices), chips, empty icon tiles |
| Paper 2 | Code blocks |
| Hairline | Card edges and the lines between rows. Nothing else |
| Ink / Ink 2 / Ink 3 | Text: primary / metadata and descriptions / disabled and chevrons |
| Memos Blue | The tint: tags, links, selected state, Save. `accentWash` behind selected or tappable things. A tag in a done task stays Memos Blue under the strike; only its words go grey |
| Danger | Errors and destructive actions. Never `.red` |

Use the asset colours, never `.secondary`, `.gray` or `Color(.systemX)`: system grays are cool,
and they look wrong on warm paper. Every pair passes contrast in light, dark and Increase Contrast.

## Type

Pick a **role**, not a size. Every role is a Dynamic Type style.

| Role | Style | For |
| --- | --- | --- |
| `.largeTitleSerif` | New York Bold 34 | The sign-in wordmark; the navigation bar's large title uses it too |
| `.memoTitle` | New York Semibold 20 | A memo's first heading; an instance name |
| `.memoBody` | SF 17 | What you wrote |
| `.memoCode` | SF Mono 15 | Code, filters, share links |
| `.rowTitle` | SF 17 | The main line of a row in a card list |
| `.sectionTitle` | SF 15 semibold, Ink 2 | Headings over groups of cards (via `SectionHeader`) |
| `.emphasis` | SF 15 semibold | Names, tile titles |
| `.supporting` | SF 15 | Descriptions, explanations, a row's second line |
| `.action` | SF 15 medium | Text that acts: Show more, chips, banner buttons |
| `.metadata` | SF 13, Ink 2 | When, who can see it, where |
| `.legend` / `.fine` | SF 12 / 11 | Chart labels and the words under a number |
| `.stat` | SF 22 semibold | A number that is the point, like a streak |

Serif is only for titles. Body text, controls and metadata are always SF.

## Space

A 4-point scale, with two half-steps for tight rows:

| `Spacing` | pt | Typical use |
| --- | --- | --- |
| `xxs` | 2 | Title ↔ subtitle |
| `xs` | 4 | Icon ↔ label in a pill; lines of metadata |
| `s` | 6 | List items; pills in a row |
| `m` | 8 | Icon ↔ text; avatar ↔ name |
| `l` | 12 | Between blocks in a card; between cards (`Metrics.blockGap`, `cardGap`) |
| `xl` | 16 | Screen margins and card padding (`Metrics.screenInset`, `cardPadding`) |
| `xxl` | 24 | Around a single message or an empty state |
| `xxxl` | 32 | Between unrelated groups |

Everything on a screen sits on the same 16-point margin, and text inside a card is inset another
16. Section headers line up with that inner text, not with the card's edge.

## Shape

Corners shrink as surfaces nest, so an inner corner is never rounder than the one around it.

| `Radius` | pt | For |
| --- | --- | --- |
| `tight` | 6 | Tiles packed in a grid: photos in a memo, the attachment library |
| `inner` | 10 | Anything inside a card or sheet: a single photo, code, a file, an icon tile, a notice |
| `card` | 16 | Cards and grouped lists |
| `panel` | 24 | An opaque panel floating alone, such as a message over the map |

Chips, pills and the floating bars are capsules. Avatars are circles.

## Surfaces

- **Cards.** `.padding(Metrics.cardPadding).cardBackground()`. The edge is a 0.5-point Hairline
  that becomes a 1-point Ink 2 line with Increase Contrast.
- **Card lists.** Rows on one card use `CardList`, never a hand-built `VStack` with `Divider`s.
  When rows lead with an icon or an emoji, pass `dividerInset: Metrics.iconRowTextInset` so the
  lines start under the text, as in the system's lists.
- **System lists and forms.** `List` and `Form` use `.paperBackground()` with `.cardRows()` on
  their sections. That way Settings, Search, Inbox and the sign-in screen use the same Card and
  Paper as the timeline, instead of the system's cool grouped grays.
- **Wells.** `.wellBackground()` for a recessed box inside a card: a file, a voice memo, a
  conflict notice.
- **Glass** is for controls only: the system toolbars, the floating bars we place by hand
  (`FloatingBar.height` = 48), the map buttons, and `Toast`. Never glass on glass, and never glass
  on content.

## Components

| Need | Use |
| --- | --- |
| A heading over cards | `SectionHeader("Saved views")`, optionally with a trailing count |
| A row that opens a page | `Chevron()` at the trailing edge |
| A symbol leading a tile or row | `IconTile(systemImage:isEmpty:)` |
| A count under a memo | `Pill(isSelected:)` |
| A card that opens something (a memo, a Library tile) | `.buttonStyle(.cardPress)`: settles to 0.98 without dimming, so the paper stays white |
| Audience or Space choice | `.buttonStyle(.chip)` / `.prominentChip` |
| Something unread | `UnreadDot(ringed:ring:)`, a dot rather than a count. The ring is the surface beneath: `.paper` on a screen, `.card` in a card |
| A person | `UserAvatar(user:size:)`: their picture, or their initial in white on their own colour from `PersonPalette` (stable per person, every colour 4.5:1 or better). You are always Memos Blue |
| A full-width primary button | `.buttonStyle(.glassProminent)` with `WideButtonLabel(title:isWorking:)` |
| A passing message | `Toast(message:)` |
| Nothing to show | `ContentUnavailableView`, with an action when there's an obvious next step |

## Screens and sheets

- **Titles.** The timeline's title is inline, so its Space menu works. Library is a hub and uses
  the large serif title. Every page you drill into from there (Activity, Tags, Map, a memo, a
  filtered timeline) uses an inline title.
- **Sheets you read** (Settings, Inbox) close with a plain `Button(role: .close)` at the trailing
  edge.
- **Sheets you edit** (the composer, Edit Comment, Save as View, Share) put `Button(role: .cancel)`
  at `.cancellationAction`, and Save at `.confirmationAction` with `.glassProminent` and
  `.tint(.memosBlue)`. Save is the only tinted glass.
- **Destructive actions** confirm with a `confirmationDialog` that says what will be lost.

## Motion

`.memosSpring` (0.35 s, no bounce) for layout. `.reactionPop` only where something lands on
purpose. `.memosFade` for things arriving in place, and `.memosPress` with the `Press` values for
custom buttons. Everything can be interrupted. Reduce Motion turns zooms into cross-fades and
removes the bounce.

**Bounce only on arrival.** Leaving is quieter than arriving: a removed reaction, a read dot, a
dismissed toast use an asymmetric transition whose removal is `.opacity` on `.memosFade`.

| `Press` | Value | For |
| --- | --- | --- |
| `opacity` | 0.7 | Chips and bar buttons; matches the design file's `--opacity-press`. Dimmer reads as disabled |
| `scale` | 0.97 | Chips and controls |
| `glyphScale` | 0.85 | A lone emoji or symbol (`.glyphPress`) |
| `cardScale` | 0.98 | Whole cards (`.cardPress`), with no dimming |
| `labelOpacity` | 0.45 | A prompt that acts as a button, such as “Capture a thought…”, which already starts in Ink 2 |

**Zoom sources carry the card's shape.** A card that a page zooms out of passes its background
and corner to `matchedTransitionSource(id:in:) { $0.background(.card).clipShape(.rect(cornerRadius: Radius.card)) }`,
so the zoom grows from paper, not a square.

## Devices

Checked in the simulator on iPhone 18 Pro (402 pt wide), 18 Pro Max (440 pt), iPhone Air (420 pt)
and iPhone Duo (466 × 678 pt). The 17 Pro and 17 Pro Max share the 18 Pro and Pro Max's sizes.

- **iPhone Duo** puts its sensor housing and status bar on the trailing edge, and the system moves
  the top toolbar buttons into a vertical rail there. That leaves about 340 points for content:
  the narrowest of these phones. Lay out against the safe area, never against the screen's width.
  Library's tiles were tightened for it.
- **Wide windows** (an unfolded Duo, iPad, Stage Manager): scrolling columns of text use
  `.readableWidth()`, which caps them at 680 points and centres them. Lists keep the system's
  readable margins.
- **Dynamic Type.** Everything scales to AX5. Fixed shapes next to text (icon tiles, avatars, the
  icon column in a card list) grow with `@ScaledMetric` through `Metrics.scaled(_:by:)`, up to
  1.6×. Rows that can't fit side by side switch to a stack with `ViewThatFits`. Two-column grids
  become one column at accessibility sizes.

## Checklist for a new screen

1. Background is `.paper`; content sits on cards or `cardRows()`.
2. Margins are `Metrics.screenInset`; cards are `Metrics.cardGap` apart.
3. Every font is a role from `Typography.swift`; every colour is an asset colour.
4. No literal padding, spacing or corner radius.
5. Glass only on controls, never on glass.
6. Checked at the default text size and at an accessibility size, in light and dark, on iPhone Duo.
