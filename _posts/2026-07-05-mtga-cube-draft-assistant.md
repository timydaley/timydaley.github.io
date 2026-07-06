---
layout: post
title: "Building an MTGA Cube Draft Assistant"
date: 2026-07-05
categories: magic machine-learning drafting
---

I've been building a draft assistant for **Magic: The Gathering Arena Cube**. The goal is simple: given the current pack, my previous picks, the cards I've seen, and the cube list, recommend a pick.

This post summarizes the current state of the project: the models, the offline results, the first Monte Carlo tree search experiments, and one real-pack example where several model variants make noticeably different choices.

## The setup

A draft pick is represented with only information available to the drafter:

- the current pack
- my drafted pool
- cards I saw but did not pick
- pack number and pick number
- the known cube list

The base model is a contextual pick policy trained from public 17lands Powered Cube draft logs. Cards are represented with learned embeddings plus Scryfall-derived features. The policy scores every card in the current pack and is trained to imitate human picks.

I also trained outcome/value components from 17lands game data:

1. a deck-quality model that predicts game win probability from a built deck,
2. a card-bonus model that estimates which maindeck cards correlate with winning,
3. DPO-style preference policies that shift the pick model toward game-data-preferred cards while trying not to destroy human-pick agreement.

## Current offline results

On a held-out Powered Cube split, the strongest human-imitation model gets roughly:

| Model / setting | Human top-1 | Human top-3 | Game-data pref. acc. |
|---|---:|---:|---:|
| Human continued, no value rerank | 0.6240 | 0.9093 | 0.5494 |
| Human continued + value rerank | 0.6234 | 0.9077 | 0.6062 |
| Safer game-data DPO + value rerank | 0.6161 | 0.9048 | 0.6406 |
| Aggressive game-data + value rerank | 0.5092 | 0.8411 | 0.7262 |

The trade-off is clear: the safer game-data model keeps most of the human-pick accuracy while improving game-data preference agreement. The aggressive model optimizes game-data preferences much harder, but it no longer behaves like a human drafter and often makes suspicious-looking picks.

## How much does previous-pick context matter?

A lot. I tested the human-continued model by removing or corrupting the previous-pick context on a 20k held-out sample:

| Context | Top-1 | Top-3 | Same top pick as full context |
|---|---:|---:|---:|
| full pool + seen | 0.6168 | 0.9070 | 1.0000 |
| no pool, keep seen | 0.4268 | 0.7545 | 0.5116 |
| keep pool, no seen | 0.6160 | 0.9065 | 0.9409 |
| no pool, no seen | 0.4070 | 0.7384 | 0.4856 |
| shuffled pool | 0.3507 | 0.6533 | 0.4088 |

The pool matters enormously. The seen-but-unpicked channel matters much less in the current model.

## Adding inference-time search

The next experiment was to add **Monte Carlo tree search at inference time**. This is not training. The model is already trained; MCTS is a slower "think harder" button.

For each candidate pick, the search:

1. forces that pick,
2. samples plausible future packs from the cube,
3. completes the draft with the policy,
4. builds/scores the final pool with the value model,
5. combines rollout value with the policy prior.

Because MTGA logs do not reveal hidden packs or opponent picks, this is an information-set approximation. It knows my pack and my pool, but future packs are sampled rather than perfectly reconstructed.

Latency with the model loaded once, on CPU, using real 17lands pick states:

| Simulations | p50 | p95 | Mean |
|---:|---:|---:|---:|
| 10 | 418 ms | 574 ms | 378 ms |
| 25 | 942 ms | 1370 ms | 850 ms |
| 50 | 1825 ms | 2697 ms | 1642 ms |

So 25 simulations is a reasonable default for a live "think harder" mode.

The current MCTS default is:

```text
--simulations 25
--rank-by final
--root-policy-weight 0.15
--root-value-weight 1.0
--root-value-mode prob
--rollout-temperature 0.0
--cpuct 1.5
```

## A real depleted-pack example

The following trace uses real packs from the held-out 17lands eval data. These are not independently sampled fake packs. They are the packs as seen by a real drafter, already depleted by previous picks. Pack sizes go from 14 down to 7.

Caveat: the later packs are real for the human's actual draft path. If a model makes a different earlier pick, the later packs are not a perfect counterfactual. Still, this is much closer to reality than testing on random packs.

### The real packs

**Pick 1, pack size 14**

Arena of Glory; Blood Crypt; Containment Priest; Endurance; Godless Shrine; Grief; Omnath, Locus of Creation; Ouroboroid; Skyclave Apparition; Snapcaster Mage; Sundering Titan; The Wandering Emperor; Wishclaw Talisman; Yavimaya, Cradle of Growth

**Pick 2, pack size 13**

Birds of Paradise; Chain Lightning; Cosmogrand Zenith; Gitaxian Probe; Hymn to Tourach; Life // Death; Multiversal Passage; Soul-Guide Lantern; Talisman of Indulgence; Talisman of Unity; Torsten, Founder of Benalia; Wasteland; Witch Enchanter // Witch-Blessed Meadow

**Pick 3, pack size 12**

Dark Confidant; Deathrite Shaman; Demonic Tutor; Expressive Iteration; Get Lost; Liliana of the Veil; Questing Druid // Seek the Beast; Razorverge Thicket; Sylvan Caryatid; Underground Mortuary; Virtue of Loyalty // Ardenvale Fealty; Windswept Heath

**Pick 4, pack size 11**

Copperline Gorge; Elvish Reclaimer; Flickerwisp; Mine Collapse; Savai Triome; Scrubland; Talisman of Progress; Trumpeting Carnosaur; Unexpectedly Absent; Valki, God of Lies // Tibalt, Cosmic Impostor; Zuran Orb

**Pick 5, pack size 10**

Archon of Cruelty; Bleachbone Verge; Mana Confluence; Questing Beast; Sacred Foundry; Blazing Firesinger // Seething Song; Stomping Ground; Taiga; Tersa Lightshatter; Titania, Protector of Argoth

**Pick 6, pack size 9**

Crucible of Worlds; Emperor of Bones; Grim Lavamancer; Jetmir's Garden; Restless Cottage; Restless Fortress; Rofellos, Llanowar Emissary; Sanguine Evangelist; Vampire Hexmage

**Pick 7, pack size 8**

Bone Shards; Collective Brutality; Exploration; Keen-Eyed Curator; Overgrown Tomb; Restless Vents; Utopia Sprawl; Winds of Abandon

**Pick 8, pack size 7**

Celestial Colonnade; Deep-Cavern Bat; Gloomlake Verge; Jadar, Ghoulcaller of Nephalia; Prismatic Ending; Sink into Stupor // Soporific Springs; Talisman of Conviction

### Model choices

| Pick | Human log | Human imitation | Safe game-data | Aggressive game-data | MCTS |
|---:|---|---|---|---|---|
| 1 | Skyclave Apparition | Snapcaster Mage | Skyclave Apparition | Ouroboroid | Blood Crypt |
| 2 | Gitaxian Probe | Gitaxian Probe | Cosmogrand Zenith | Birds of Paradise | Hymn to Tourach |
| 3 | Windswept Heath | Demonic Tutor | Windswept Heath | Demonic Tutor | Demonic Tutor |
| 4 | Scrubland | Scrubland | Unexpectedly Absent | Zuran Orb | Valki, God of Lies // Tibalt, Cosmic Impostor |
| 5 | Sacred Foundry | Archon of Cruelty | Sacred Foundry | Titania, Protector of Argoth | Archon of Cruelty |
| 6 | Sanguine Evangelist | Emperor of Bones | Sanguine Evangelist | Emperor of Bones | Emperor of Bones |
| 7 | Winds of Abandon | Collective Brutality | Winds of Abandon | Keen-Eyed Curator | Bone Shards |
| 8 | Deep-Cavern Bat | Deep-Cavern Bat | Prismatic Ending | Deep-Cavern Bat | Deep-Cavern Bat |

### Final pools

**Human log**

Skyclave Apparition; Gitaxian Probe; Windswept Heath; Scrubland; Sacred Foundry; Sanguine Evangelist; Winds of Abandon; Deep-Cavern Bat

**Human imitation**

Snapcaster Mage; Gitaxian Probe; Demonic Tutor; Scrubland; Archon of Cruelty; Emperor of Bones; Collective Brutality; Deep-Cavern Bat

**Safe game-data**

Skyclave Apparition; Cosmogrand Zenith; Windswept Heath; Unexpectedly Absent; Sacred Foundry; Sanguine Evangelist; Winds of Abandon; Prismatic Ending

**Aggressive game-data**

Ouroboroid; Birds of Paradise; Demonic Tutor; Zuran Orb; Titania, Protector of Argoth; Emperor of Bones; Keen-Eyed Curator; Deep-Cavern Bat

**MCTS value-conservative**

Blood Crypt; Hymn to Tourach; Demonic Tutor; Valki, God of Lies // Tibalt, Cosmic Impostor; Archon of Cruelty; Emperor of Bones; Bone Shards; Deep-Cavern Bat

## What happened in this example?

The safe game-data model most closely follows the human's white/fixing lane. It takes Skyclave Apparition, Windswept Heath, Sacred Foundry, Sanguine Evangelist, and Winds of Abandon.

The human-imitation model actually chases more raw power here: Snapcaster Mage, Demonic Tutor, Archon of Cruelty. That is interesting because it is the model optimized for human agreement overall, but on this trace it is less committed to the logged human's fixing-heavy path.

The aggressive game-data model still looks unsafe. Picks like Ouroboroid, Zuran Orb, Titania, and Keen-Eyed Curator are plausible outputs of a model chasing static game-outcome bonuses, but they look contextually dubious.

MCTS is heavily path-dependent. After taking Blood Crypt, it moves into a black/red power lane: Hymn to Tourach, Demonic Tutor, Valki/Tibalt, Archon, Emperor of Bones, Bone Shards. This may be a coherent line, but it is also a reminder that search amplifies early assumptions. If the first pick is off, the whole searched line can drift.

## Current takeaways

1. The base policy is already strong at human-pick imitation.
2. Prior picks matter a lot; removing the pool cuts top-1 accuracy by about 20 points.
3. Safe game-data tuning improves game-data preference agreement while mostly preserving human agreement.
4. Aggressive game-data tuning is useful for analysis, but not safe as a default recommendation policy.
5. MCTS is promising as an inference-time "think harder" mode, especially at 25 simulations, but its disagreements need auditing.
6. Real depleted-pack traces are much more informative than random pack examples.

The next thing I want is a larger disagreement audit: sample many real draft prefixes, compare human / safe / MCTS / aggressive choices, and manually review the cases where MCTS changes the pick.
