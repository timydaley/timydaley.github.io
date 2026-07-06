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

The base model is a contextual pick policy trained from public 17lands Powered Cube draft logs. Each card is represented by combining a card-specific learned vector with features extracted from Scryfall metadata and rules text: mana value, color and color-identity bits, card-type bits, rarity, power/toughness fields, keyword indicators, and oracle-text features. In model terms, the representation is roughly

```text
card_repr = learned_card_embedding + alpha * MLP(scryfall_features)
```

where `alpha` starts high and is annealed to a nonzero floor. This lets common cube cards specialize through their learned embeddings while still giving reasonable representations to changed or unseen cube cards from their rules text and metadata. The policy scores every card in the current pack and is trained to imitate human picks.

Models trained:

1. **Human imitation / human continued** is the pick policy trained only to match logged 17lands human picks. This is the most human-like baseline.
2. **Deck-quality model** is a separate value model trained from 17lands game results. It takes a completed 40-card deck plus sideboard and metadata, then predicts game win probability. I use it to ask: "if this draft pool became this deck, how good would the deck be?"
3. **Value reranking** means taking the human pick policy's score for each card in the pack, then adding a small bonus from the deck-quality model after hypothetically adding that card to the pool.
4. **Card-bonus model** is a simpler outcome model trained from game results. Instead of evaluating full deck structure, it learns a per-card win-rate bonus: cards that often appear in winning maindecks get positive bonuses, cards that underperform get lower bonuses. This is useful, but less contextual than the deck-quality model.
5. **Safe game-data** is a DPO fine-tune that nudges the pick policy toward card-bonus-preferred picks while staying close to the human-imitation model.
6. **Aggressive game-data** is a stronger DPO fine-tune that optimizes the card-bonus preferences harder. It improves game-data preference accuracy, but loses a lot of human-pick agreement and sometimes makes weird-looking picks.
7. **MCTS value-conservative** is not a separately trained model. It is inference-time search using the value-conservative policy as a prior and the deck-quality/value model to score simulated draft continuations.

## Model and training details

The pick model is a cube-context contextual preference ranker. For a cube with `C` cards, every training example has a `C`-dimensional current-pack mask, pool count vector, seen-but-unpicked count vector, and cube mask. The model first computes `card_repr` for every card in the cube. It then uses separate DeepSets encoders for three unordered sets:

```text
pool_repr = DeepSet(cards in my pool)
seen_repr = DeepSet(cards I saw but passed)
cube_repr = DeepSet(cards in the cube list)
```

The draft context is the concatenation of those three set embeddings, an explicit WUBRG color-commitment vector from the pool, and learned embeddings for pack number and pick number. A small MLP maps that context to the same dimension as a card representation. Each card is scored by a dot product plus a card bias:

```text
context = MLP(pool_repr, seen_repr, cube_repr, color_commit, pack_idx, pick_idx)
score(card | context) = dot(context, card_repr(card)) + bias(card)
```

The policy is trained over the in-pack support only. The main loss is a contextual preference / triplet ranking loss: the logged human pick should score at least a margin above every other card in the pack.

```text
loss = mean_over_unpicked_cards max(0, margin - score(picked) + score(unpicked))
```

In the current implementation the representation dimension is 128, the hidden dimension is 256, and the default margin is 0.2. The Scryfall feature contribution `alpha` anneals from 1.0 to a floor of 0.3 over early training. I also use random cube-list masking during training so the model is robust to partial or changing Arena Cube lists.

The outcome model is separate. It takes a built deck and sideboard, encodes maindeck and sideboard cards with DeepSets over the same card representation, concatenates rank/event/color covariates, and predicts game win probability. I train this on 17lands game data, both per-game and aggregated by `(draft_id, build_index)`. For deployment, a simple heuristic deckbuilder maps a draft pool to a 40-card deck before scoring.

The game-card bonus model is an even simpler outcome model:

```text
logit(win_probability) = intercept + sum(card_in_maindeck * card_bonus) + covariates
```

I tested pair-interaction variants, but they overfit relative to the card-only model. The learned top bonuses were plausible Powered Cube cards: Ancestral Recall, Time Walk, Black Lotus, Sol Ring, Mana Crypt, and the Moxen.

Finally, I generated static preference pairs for DPO. For a logged pick state, if one in-pack candidate has a sufficiently higher learned game-card bonus than another, that pair becomes `(preferred, rejected)`. DPO fine-tunes the pick policy toward those game-data preferences while anchoring it to the human-pick reference policy with a KL penalty. This gives the safe/aggressive trade-off in the table below.

## Current offline results

On a held-out Powered Cube split, the strongest human-imitation model gets roughly:

| Model / setting | Human top-1 | Human top-3 | Game-data pref. acc. |
|---|---:|---:|---:|
| Human continued, no value rerank | 0.6240 | 0.9093 | 0.5494 |
| Human continued + value rerank | 0.6234 | 0.9077 | 0.6062 |
| Safer game-data DPO + value rerank | 0.6161 | 0.9048 | 0.6406 |
| Aggressive game-data + value rerank | 0.5092 | 0.8411 | 0.7262 |

It seems that the safer game-data model keeps most of the human-pick accuracy while improving game-data preference agreement. The aggressive model optimizes game-data preferences much harder, but it no longer behaves like a human drafter and often makes suspicious picks.

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

The next experiment was to add **Monte Carlo tree search at inference time**. This is not training. The model is already trained; MCTS is a search procedure that evaluates each legal pick by simulating possible continuations of the draft and scoring the resulting pools.

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

So 25 simulations is a reasonable default for live search-based reranking.

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

The most interesting part of the real-pack example is that MCTS appears to choose a lane and strategy early. After taking Blood Crypt, it moves into a black/red, maybe Rakdos-reanimator-ish, power lane: Hymn to Tourach, Demonic Tutor, Valki/Tibalt, Archon of Cruelty, Emperor of Bones, Bone Shards. Whether or not Blood Crypt is the best first pick, the later MCTS picks are at least coherent with that early commitment.

The other models look less strategically consistent in this trace. Human imitation takes individually strong cards, but jumps between Snapcaster, Demonic Tutor, Scrubland, Archon, black interaction, and Deep-Cavern Bat without as clear a deck plan. Safe game-data follows the logged human's white/fixing lane more closely, but sometimes takes value/removal cards over synergy. Aggressive game-data mixes value and combo-looking cards and produces the least coherent path. This is a useful qualitative difference: search can amplify a questionable early lane choice, but it can also make the subsequent picks more internally consistent.

## Current takeaways

1. The base policy is already strong at human-pick imitation.
2. Prior picks matter a lot; removing the pool cuts top-1 accuracy by about 20 points.
3. Safe game-data tuning improves game-data preference agreement while mostly preserving human agreement.
4. Aggressive game-data tuning is useful for analysis, but not safe as a default recommendation policy.
5. MCTS is promising as an inference-time search/reranking method because it often commits to a lane and then chooses strong cards for that lane. Its disagreements still need auditing, especially when the initial lane choice is questionable.
6. Real depleted-pack traces are much more informative than random pack examples.

The next thing I want is a larger disagreement audit: sample many real draft prefixes, compare human / safe / MCTS / aggressive choices, and manually review the cases where MCTS changes the pick.
