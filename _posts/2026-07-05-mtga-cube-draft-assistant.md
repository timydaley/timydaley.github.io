---
layout: post
title: "Building an MTGA Cube Draft Assistant"
date: 2026-07-05
last_modified_at: 2026-09-20
description: "What Flash, reanimation targets, and a disappointing draft taught me about evaluating an Arena Powered Cube assistant."
categories: magic machine-learning drafting
---

*Rewritten September 20, 2026, after auditing the models and evaluation.*

You have Worldspine Wurm in your pool. The next pack offers Flash, Counterspell, and Preordain.

Counterspell and Preordain are easy cards to like. Flash needs a reason. With the Wurm, you have one: put it onto the battlefield, decline to pay the extra mana, and sacrifice it. Its death trigger leaves three 5/5 tramplers. That should change how you look at this pack.

I built an assistant to help with exactly these decisions in MTG Arena Powered Cube. I’ve been unhappy with its recommendations in actual play. The offline numbers looked more encouraging than the decks, and combo picks were a particular frustration.

So I went back through the system and its evaluation. In a small test built around that Flash pack, adding Worldspine Wurm actually moved Flash’s score in the wrong direction relative to Counterspell. The assistant had access to the pool. It still failed the interaction I wanted it to recognize.

That result is a useful place to start explaining what I’ve built, what went wrong, and what I want the next version to do.

## Start with the deck you’re trying to build

Arena Powered Cube rewards cards that do something outrageous together. It also rewards being able to cast your spells and having a turn-two play.

The [official Arena Powered Cube guide](https://magic.wizards.com/en/news/mtg-arena/arena-powered-cube-draft) covers both ends: individually powerful cards, combinations such as Underworld Breach with Brain Freeze and Lion’s Eye Diamond, and decks that mix several plans. That’s the balance I want the assistant to understand.

Suppose you already have Entomb and Archon of Cruelty. Reanimate fills a very specific hole. Another enormous creature might be useful, but it doesn’t solve the same problem. If you already have several ways to bring creatures back and nothing worth returning, that decision changes.

The same reasoning applies to less spectacular picks. A deck full of expensive threats may need cheap interaction. A multicolor pool may need fixing before another splash card. Recognizing a combo should help the assistant see those tradeoffs, including when pursuing the combo costs too much.

Older Arena Cube strategy writing makes this concrete by asking what each card contributes to your plan. [MTG Arena Zone’s general strategy guide](https://mtgazone.com/arena-cube-draft-a-general-in-depth-strategy-guide/) works through examples involving aggressive decks, expensive threats, and removal. Its card recommendations belong to an older cube, but that habit of explaining a pick through the deck is useful here.

## What the assistant actually sees

The assistant reads the current pack, my drafted cards, cards I’ve seen and passed, the pick number, and the configured cube list. It starts with a model trained to imitate choices in public 17Lands draft logs. Previous picks already influence its scores.

I then experimented with learning from game results. One model estimates the strength of a completed deck. Another learns a bonus for each card from the decks it appears in. I used those bonuses to generate preferred picks and train the assistant to follow them more closely.

There’s a catch: the card-only bonus doesn’t change when the pool changes. The pick model can see Entomb and Archon, while its training target keeps rewarding the same ordering of cards. A model with contextual inputs can still be pushed toward a largely fixed pick order.

The completed-deck model had a different problem. During drafting, a simple deckbuilder filled an incomplete pool with basic lands before evaluating it. Early in pack one, that can mean judging one spell and 39 basics. A model trained on finished decks has little reason to give useful advice about that input.

New cards also need special handling as the cube changes. The assistant can borrow representations from similar known cards, using metadata, rules text, and role tags. That helps it produce recommendations for unfamiliar cards; it doesn’t establish that it understands their combos. My original writeup also overstated the main pick model’s use of rules text. That text is part of the fallback, while the main model uses learned card representations and structured attributes.

## Put the same pack in two different pools

Before training another version, I wanted an evaluation that exposed these problems directly.

I assembled a queue of 150 cases tied to a saved 540-card cube list: 126 logged decisions and 24 deliberately constructed situations. The development portion contains 82 logged picks and nine pairs of constructed situations. Fifty cases remain reserved and unevaluated.

For each pair, the pack stays fixed and one card in the pool changes. Then I check whether the focal card gains or loses ground against a specified alternative. This tests a narrower question than “did it make the best pick?” It asks whether a relevant change in the pool moved its judgment in the proposed direction.

These examples were authored with AI assistance and still need independent review. They’re useful debugging cases, with proposed expectations that another drafter should be able to challenge.

### Flash with a reason to cast it

**Pack:** Flash, Counterspell, Preordain.

**Starting pool:** Polluted Delta, Ponder, Elder Gargaroth.

**Change:** Replace Elder Gargaroth with Worldspine Wurm.

I expected Flash to gain ground against Counterspell. In both pools, the base policy ranked Counterspell first, Preordain second, and Flash last. More troublingly, Flash’s relative score fell after adding the Wurm. The aggressive configuration moved in the same wrong direction.

That doesn’t prove Flash must be the pick in every real draft containing a Wurm. These are tiny constructed pools. But it identifies a specific interaction to investigate, instead of leaving me with a vague feeling that the recommendations are off.

### Reanimation has to respect the target

**Pack:** Persist, Reanimate, Fatal Push.

**Starting pool:** Entomb, Bloodstained Mire, Archon of Cruelty.

**Change:** Replace Archon with Titania, Protector of Argoth.

[Persist](https://mtg.wtf/card/spg/42/Persist) can return a nonlegendary creature. Titania is legendary. Reanimate can return either creature, so replacing Archon with Titania removes a use for Persist that Reanimate retains.

I expected Persist to lose ground against Reanimate. Both tested configurations moved the other way.

A broad “reanimator synergy” bonus could miss this distinction too. The assistant needs to know which spell works with which target. Matching colors and archetype names won’t be enough.

### A small response can still leave the combo last

**Pack:** Brain Freeze, Remand, Ponder.

**Starting pool:** Underworld Breach, Polluted Delta, Scalding Tarn, Abrade.

**Change:** Replace Abrade with Lion’s Eye Diamond.

Here, Brain Freeze gained ground against Remand in both tested configurations, as proposed. Yet it remained last in both rankings. The pool change produced a response, but not enough to change the recommendation.

This matters when reading the results below. A directional check can pass on a tiny score movement. It doesn’t mean the assistant found the combo pick or understood how to execute it.

## What the numbers tell us

Here’s the current development replay. “Logged-pick agreement” means choosing the same card as the person in the log. The other column counts the nine paired checks described above.

| Configuration | Logged-pick agreement, 82 picks | Proposed direction followed, 9 pairs |
|---|---:|---:|
| Base policy, score adjustments off | 29/82 (35.4%) | 5/9 |
| Current default | 29/82 (35.4%) | 5/9 |
| Aggressive preference training + deck-value adjustment | 21/82 (25.6%) | 4/9 |
| Fixed card-prior comparator | 20/82 (24.4%) | 0/9 |

The base and default use the same outcome-weighted checkpoint. The default adds configured card priors and companion rules; its deck-value and heuristic synergy adjustments are off. The aggressive configuration changes both the trained model and the scoring adjustments, so this comparison doesn’t isolate either change.

The fixed comparator uses an incomplete list of card priors with alphabetical tie-breaking. It isn’t an expert tier list. It also cannot respond to a pool change, so its zero in the last column follows from its design.

All 82 logged decisions come from just two drafts. Agreement with those choices is descriptive, and disagreement may sometimes be justified. None of the 150 cases has independently approved strategic labels yet. The replay is reproducible, but it doesn’t give us a reliable estimate of drafting skill or win rate.

The July experiments answer another question. On an archived sample of 20,000 human pick states, stronger preference training reduced agreement with the logged picks while increasing agreement with a separate model’s generated preferences:

| Historical configuration | Same first choice as human | Agreement with value-generated preferences |
|---|---:|---:|
| Continued human imitation | 62.4% | 54.9% |
| Gentler preference training + value adjustment | 61.6% | 64.1% |
| Aggressive preference training + value adjustment | 50.9% | 72.6% |

These are saved July results, not a fresh run of the repaired system. They also use different data and configurations from the small September replay, so the percentages shouldn’t be compared across tables as progress over time.

Most importantly, that right-hand column measures agreement with generated preferences. Calling it “game-data preference accuracy,” as I did before, made it too easy to read as evidence of better gameplay. Optimizing toward a teacher shows that the model can follow the teacher. The teacher still needs to be right.

The [revised paper](/mtga_cube_draft_assistant/mtga_cube_draft_icml2026.pdf) gives the exact configurations, additional historical results, and artifact checks behind these tables.

## Back at the draft table

One draft from the original post captures the frustration. I ended up with a controlling artifact deck, went 2–2, and won both games in which I played Ugin. I also made a costly mistake by forgetting to crew Reckoner Bankbuster and kill Kaito when I had the chance.

![The original pack-three, pick-one screenshot from the controlling artifact draft.](/mtga_cube_draft_assistant/pack3_pick1.png)

*A screenshot from the original draft, using an earlier cube and assistant version.*

It was an interesting deck to play. It didn’t tell me whether following the assistant made my draft better. My picks, deckbuilding, play decisions, and opponents all contributed to the result.

The audit also found problems that made collecting better evidence harder: stale pool state could survive into a new draft, some loss labels were skipped, and game records could be associated with drafts solely because they occurred nearby in time. Those paths have been repaired. Unverified game-to-draft links are now excluded from training, and no new model has been trained from the repaired gameplay pipeline yet.

Those fixes make the system easier to evaluate. They don’t repair its strategic judgment by themselves.

## What I want from the next version

I want the assistant to identify what a developing deck is missing. For reanimator, that means keeping track of setup, compatible targets, and ways to return them. For a control deck, it also means noticing whether another expensive finisher leaves the early turns empty.

A combo piece should gain value when its partners are present, while the assistant still considers mana, redundancy, and how much draft remains. Early speculation and a pack-three commitment are different decisions. A useful recommendation should explain that difference in language I can act on.

For the Reanimate example, an explanation I’d like to see is: “You already have Entomb and Archon. Reanimate gives you a way to use them; another target leaves that job unfilled.” That’s a target for the redesign, not something the current assistant has demonstrated reliably.

The next steps are to get the contextual examples reviewed, represent these card packages explicitly, and build plausible decks before asking a value model to judge them. Then I want to compare completed drafts under controlled conditions and collect games with verified links to the recommendations actually followed. More search can wait until there’s a better-supported way to judge what it finds.

The test I keep coming back to is that first pack. If the assistant sees Worldspine Wurm arrive in my pool, I want its advice about Flash to change for a reason a drafter can recognize. There’s still work to do before I can trust it with the rest of the draft.
