---
layout: post
title: "Building an MTGA Cube Draft Assistant"
date: 2026-07-05
last_modified_at: 2026-09-20
description: "RL-guided assistance for MTGA powered cube"
categories: magic machine-learning drafting
---


# Intro

I love mathematical card games.  Originally this was poker, but now it's 
Magic the Gathering.  Strategic thinking under uncertainty is particularly
compelling to me, and is also applicable to my job in developing machine
learning algorithms.  Which, of course, means I should apply what I've 
learned in my career and research to the problem of mathematical card games.

In MtG(Magic the Gathering) there are many ways to play.  One of the most 
challenging ways is Limited, or drafting. 
From [Bertram et al. 2021](https://arxiv.org/pdf/2105.11864), 

> In contrast to formats where decks are constructed
separately from playing, drafting features a first game phase in
which players form a pool of cards, from which they later build
their decks. The pool of cards is chosen from semi-random
selections of cards, so-called packs. Each pack of MTG cards
consists of 15 different cards of four different rarities: eleven
Common, three Uncommon, and one Rare or Mythic card.1
Rare cards appear more frequently than Mythic ones. Over
the course of the whole draft, each player chooses a deck of
45 cards sequentially. Players get their cards by choosing from
many packs as follows: Each of the eight players in a draft
starts with a full pack of 15 cards, selects a single card from
it, and passes the remaining 14 cards on to the next player. In
the following rounds, players select from 14, 13, . . . cards. This
process continues until all 15 cards of the original packs are
chosen. This process is repeated for an additional two packs,
such that each player selects 45 cards in total. In each round,
packs are passed around in the same direction.

In this way, there is not only the strategy of playing but there
is also the additional strategy associated with selecting which
cards to draft.  Part of this is identifying which cards are powerful,
but also which cards work together and are playable in what will
be your deck.  For example, drafting 
[Cryptic Command](https://scryfall.com/card/ima/48/cryptic-command)
in a white-red aggressive deck will not work well. 

In my opinion the pinnacle of drafting is cube draft.  I was first
introduced to cube draft by my friend Adam Ericksen.  
There's a deep understanding is required to identify what cards work well 
together, what strategies or lanes are open and available,
and having cards that can answer, block, or stymie
what your oppenents are trying to do.  

For example, suppose you've started a draft with a 
[Phelia](https://scryfall.com/card/mh3/40/phelia-exuberant-shepherd)
followed by a fetch land and a [Fury](https://scryfall.com/card/mh2/126/fury).  
The next pack you see an
[Archon of Cruelty](https://scryfall.com/card/frc/47/archon-of-cruelty), 
the best reanimation target.  This indicates that 
reanimation might be a strategy to consider because none of the
players in front of you have selected that card.  



# A draft helper

My drafting ability is quite mid, despite my understanding of the game.
Part of that I don't fully have a good grasp on all of the strategies, 
part of that is a lack of experience.  
So to help me I decided to build a draft helper to 
assist with draft picks.  


To warm-start the model I used 
a learned identity embedding, with structured attributes such as mana cost and 
color, and a frozen MiniLM embedding of its rules text.
Four-head attention lets each candidate card attend to previously drafted cards. 
The model trains on about 88,000 human draft decisions using cross-entropy over 
the cards actually offered in each pack.
I next added [17lands](https://www.17lands.com/card_data?expansion=Cube+-+Powered&format=PremierDraft&time_period=LATEST_EVENT)
Game-In-Hand card ranking.  
This metric tells us the winning rate of a card if it is drawn at any point in 
a game. Note that 17lands win rates average to higher than 50% because 
the pool of players who use 17lands have a higher than average win rate.
I added a fixed score derived from the normalized log-odds of 
the 17Lands GIH win rate. So the baseline score is the relative
ranking of 17lands GIH win rate.  
Training then learns pool-dependent corrections, supplemented by historical 
statistics measuring whether a card is picked more often when another card 
is already in the pool.

The next information we can use is our own selection win rates.  
For a given card selected, what was it's win rate, as well as the
win rate in combination with other cards selected.  
Finally, we also have information from our opponents.  We
see which cards they play (but not all cards they draw) and can penalize
cards we see from our opponents when we win (and they lose)
and reward cards we see them play when we lose. 
Picks receive a smoothed weight based on their draft’s results. 
We use reward-informed offline policy adaptation to adapt to 
actual picks and game outcomes.  
We backpropagate game outcome-prediction and pick 
behavior cloning (imitation loss) rather 
than directly maximize expected win reward.
For example, if a combination appears in a winning deck but the 
outcome predictor assigns a low win probability, the training gradient adjusts 
the representations toward a higher predicted probability for that observation. 
Losses provide the opposite signal. 
This does not establish which combination caused the result, instead the model learns 
statistical associations.

Because we are training on what I actually chose during previous
drafts, I've found the model tends to upweight strategies that I have historically
had success with like reanimator, artifacts, and control tempo. 


Full description of the model is available 
[here](https://timydaley.github.io/mtga_cube_draft_assistant/mtga_cube_draft_icml2026.pdf). 


# Model performance

| Model version | Drafts | Wins | Losses | Games | Win rate |
|---|---:|---:|---:|---:|---:|
| Without draft helper | 6 | 17 | 18 | 35 | 48.6% |
| Sept. 21 — Pool attention + card associations | 3 | 11 | 9 | 20 | 55.0% |
| Sept. 22 — Personal fine-tuning | 1 | 2 | 3 | 5 | 40.0% |
| Sept. 24 — GIH prior + personal fine-tuning | 7 | 31 | 17 | 48 | 64.6% |
| Total | 17 | 61 | 47 | 108 | 56.5% |

![Winrate over time](/mtga_cube_draft_assistant/winrate_over_time.png)

You can see that my win rate prior to this experiment was ~50%, which
is pretty poor.  Due to the prize structure that win rate will lose 
pretty quickly.  
After the final model fine-tuning the win rate improved dramatically, though
the sample size is small.  
I think the experience and the suggestions made me think much more about
cards in a holistic sense. 

# Example

Here's an example of the model suggestions from a real draft.  

![](/mtga_cube_draft_assistant/portal-draft-example.png)

[Portal to Phyrexia](https://scryfall.com/card/bro/240/portal-to-phyrexia)
is a great choice in a Tinker deck.  Additionally, Phelia
can blink the Portal to act as repeatable removal and grow Phelia.
It works so much better with the cards we have in the deck than 
anything else.  Ravenous robots can work well if we want to lean into
Bolas' Citadel, but Portal is stronger and we may want to consider dropping 
Citadel in favor of Portal for the primary Tinker target.

![](/mtga_cube_draft_assistant/balance-draft-example.png)

In pack 2 Balance is suggested, and it works very well in our deck.  
We will be artifact heavy, with a low curve, and want to spew out 
cheap costing artifacts quickly.  This works very well in a Balance
deck, and can put our opponent on an uphill climb in terms of 
resources.  

I ended up going 5-3 with this deck.  Two losses were due to clear 
misplays on my part.  Like decking myself with two 
[Nexus of Becoming](https://scryfall.com/card/big/25/nexus-of-becoming)
out because I [Fractured Identity](https://scryfall.com/card/c17/37/fractured-identity)
my opponents Nexus to slow down their card draw. 
I realized my mistake 4 turns later.   
A very fun and interesting deck to play. 
