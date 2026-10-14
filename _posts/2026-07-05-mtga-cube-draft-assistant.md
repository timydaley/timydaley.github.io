---
layout: post
title: "Building an MTGA Cube Draft Assistant"
date: 2026-10-13
last_modified_at: 2026-10-13
description: "Learning card combinations from draft choices and game results in Arena Powered Cube."
categories: magic machine-learning drafting
---

You have Worldspine Wurm in your pool. The next pack offers Flash, Counterspell, and Preordain.

Counterspell and Preordain are strong cards. Flash becomes interesting because of what you already have: put the Wurm
onto the battlefield, decline to pay the extra mana, and sacrifice it. Its death trigger leaves three 5/5 tramplers.
That interaction should change how the assistant evaluates the pack, even if it doesn't settle the pick.

This is the problem I've been working on with my Arena Powered Cube draft assistant. A ranking of individual cards is a
useful starting point. Building a deck requires deciding which cards belong together, what the pool is missing, and
whether the mana can support the plan.

The current model starts with 17Lands card win rates and learns adjustments from draft choices and my game results. It
responds correctly to some combinations, still misses others, and now has enough recorded games to show results by model
version.

## From a card ranking to a draft pick

A draft gives each player 45 cards, selected one at a time from passing packs. The eventual deck needs at least 40
cards, including basic lands added afterward. Some picks won't make the deck. Others are speculative until the right
support arrives. [Bertram and colleagues](https://arxiv.org/pdf/2105.11864) describe this as learning which card best
extends an existing collection.

In Powered Cube, that distinction matters. Entomb and Archon of Cruelty make a spell that returns creatures from the
graveyard especially useful. A pool with several reanimation spells and no worthwhile target has a different need.
Meanwhile, a fetch land or cheap removal spell can be more valuable than another piece of an ambitious plan.

I use Games in Hand win rate, or GIH WR, from a September 24 export of 17Lands ratings as the starting ranking. With an
empty pool, the assistant follows that ordering exactly. Once I've picked a card, learned contextual adjustments can
change the order.

GIH WR is an observed result from decks and players that used a card. It doesn't tell us how much adding that card would
improve this particular pool. That's the job of the contextual model.

## What the model knows about a card

Each card has a 64-dimensional representation built from three parts: a learned identity vector, structured attributes,
and a representation of its rules text.

The attributes include mana value, colors, color identity, card types, power and toughness, rarity, and keywords. The
text input includes the mana cost, full type line, rules text, and power and toughness. A frozen MiniLM language model
encodes that text; a learned projection adapts it for drafting. The current model inherits card representations from
earlier draft training rather than starting them from scratch.

For each card in the pack, attention looks at the cards already drafted. A separate statistical adjustment captures
whether players select that card more often when a particular partner is in their pool. Those associations can reflect
combinations, colors, or broader deck plans. They aren't verified rules about how cards interact.

The model also sees passed cards, draft position, and whether the observed history is complete. There is no explicit
list of completed combos or rules engine checking legal targets. Having the text available gives the model useful
information, but doesn't guarantee that it understands an interaction.

## Learning from my games

The contextual model trains on 87,999 public draft decisions. Personal fine-tuning uses 180 picks from four drafts and
67 games, including losses.

Games influence training in two ways. When a game can be linked to a draft, that draft's results adjust the weight of
its recorded picks. The adjustment is smoothed so a handful of wins doesn't dominate training, and losing drafts still
contribute.

An auxiliary task predicts my game result from my deck and the opponent cards observed during play. Each side has its
own summaries of cards and pair interactions. Opponent information is incomplete, so an observed set of cards isn't
treated as a full deck list. This task changes the card representations used by the pick model; it doesn't directly add
a win bonus to a recommendation.

This gives the assistant a way to learn from both sides of a game without my writing a rule for every combination. It
also leaves an attribution problem: a win doesn't tell us which card, interaction, or play decision caused it.

## Does the same pack get different advice?

I evaluate contextual responses by holding the pack fixed and changing one card in the pool. Then I measure how the
score difference between two candidates changes. The GIH prior cancels in that comparison, leaving the response to
context.

The current checkpoint follows the proposed direction in seven of nine development cases. Only one changes the top
recommendation: Channel becomes the first choice when its payoff is present. These cases are debugging tools developed
with AI assistance and informal player review, not an independent measure of drafting skill.

For the Flash example, replacing Elder Gargaroth with Worldspine Wurm now raises Flash's score relative to Counterspell.
The recommendation at the top still stays the same. That's a useful response, but a narrower result than demonstrating a
better pick.

In a pool containing Underworld Breach, replacing Abrade with Lion's Eye Diamond raises Brain Freeze's score relative to
Remand. Brain Freeze already leads in the control pool, so this case also passes without changing the recommended card.

Reanimation exposes two remaining problems. Adding a target reduces Reanimate's score relative to Griselbrand, when the
expected response is an increase. In another case, replacing Archon of Cruelty with Titania increases Persist's score
relative to Reanimate. Persist cannot return the legendary Titania, so that response goes the wrong way. Reanimate
remains the top choice in both states, illustrating why a plausible recommendation alone doesn't establish correct
treatment of the interaction.

On historical validation data, the model matches 1,138 of 2,048 recorded choices, or 55.57%. That validation set has
been reused during development. It also matches 106 of the 180 personal picks used in training, or 58.89%; that second
number measures training fit. Neither percentage measures combo recognition or game win rate.

## Results at the draft table

The game records can be linked to 17 complete drafts. Six were drafted without the helper; the remaining drafts have
recorded model configurations. Here are the results grouped by version:

| Model version | Drafts | Wins | Losses | Games | Win rate |
|---|---:|---:|---:|---:|---:|
| Without draft helper | 6 | 17 | 18 | 35 | 48.6% |
| Sept. 21 — Pool attention + card associations | 3 | 11 | 9 | 20 | 55.0% |
| Sept. 22 — Personal fine-tuning | 1 | 2 | 3 | 5 | 40.0% |
| Sept. 24 — GIH prior + personal fine-tuning | 7 | 31 | 17 | 48 | 64.6% |
| Total | 17 | 61 | 47 | 108 | 56.5% |

Win rate is wins divided by games within each group. Fourteen other game records lack a unique link to a complete draft
and are excluded from this table.

![Win rate for each of 17 drafts, with model checkpoint transitions
marked.](/mtga_cube_draft_assistant/winrate_over_time.png)

Each point shows that draft's own win rate. The dashed lines mark the first draft associated with each recorded model
version; the labels give its training date. They aren't exact training times on the draft axis.

The latest version is associated with 31 wins in 48 games, compared with 17 wins in 35 games without the helper. That's
encouraging, but these are small groups from one player, with different decks and opponents. The September 22 result
comes from just one draft. Recorded configurations can also come from replaying logs, so they do not establish that
every recommendation was displayed or followed during play.

More training data and later model versions arrived together. These results cannot isolate the effect of additional
training examples, or establish that the assistant caused the higher win rate. They do show the outcomes draft by draft,
including the earlier games and the losses.

The [paper](/mtga_cube_draft_assistant/mtga_cube_draft_icml2026.pdf) describes the current model, training procedure,
contextual diagnostics, and game analysis in detail.
