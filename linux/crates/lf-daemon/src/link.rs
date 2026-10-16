//! The agent link's state, owned by the controller (see `crate::protocol`
//! and `linux/AGENT-LINK.md`):
//!
//! - **Suggestions**: dictionary words agents suggested, waiting for review
//!   (`localflowctl dict review`). At most [`MAX_SUGGESTIONS`], each for
//!   [`SUGGESTION_TTL`].
//! - **Project words**: at most [`MAX_SETS`] named sets of at most
//!   [`MAX_SET_WORDS`] entries each, boosted at strength 1 until their time
//!   is up. They never touch `dictionary.json`.
//! - **Agent report**: the latest status counts, until their time is up.
//!
//! All of it is held in memory only, so a restart drops it. Words and set
//! names are user content: they never reach logs or `Debug` output.

use std::time::{Duration, Instant};

use lf_asr::dictionary::{self as rules, DEFAULT_STRENGTH, DictionaryEntry};
use lf_asr::tokenizer::Tokenizer;

use crate::dictionary::Dictionary;
use crate::protocol::AgentCounts;

/// Most suggestions pending at once.
pub const MAX_SUGGESTIONS: usize = 16;
/// How long a suggestion stays pending.
pub const SUGGESTION_TTL: Duration = Duration::from_secs(24 * 3600);
/// Most project word sets at once.
pub const MAX_SETS: usize = 4;
/// Most entries in one project word set.
pub const MAX_SET_WORDS: usize = 64;

/// Too many suggestions or sets.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Full;

/// A suggestion waiting for review.
pub struct Pending {
    pub id: u64,
    /// Validated and normalized, at strength 1.
    pub entry: DictionaryEntry,
    key: String,
    queued: Instant,
}

/// Pending suggestions, oldest first.
pub struct Suggestions {
    pending: Vec<Pending>,
    next_id: u64,
}

impl Default for Suggestions {
    fn default() -> Suggestions {
        Suggestions {
            pending: Vec::new(),
            next_id: 1,
        }
    }
}

impl Suggestions {
    pub fn len(&self) -> usize {
        self.pending.len()
    }

    pub fn is_empty(&self) -> bool {
        self.pending.is_empty()
    }

    /// Queues `entry` unless its key is already pending (it then keeps its
    /// place).
    pub fn add(&mut self, entry: DictionaryEntry, now: Instant) -> Result<(), Full> {
        let key = entry.key();
        if self.pending.iter().any(|p| p.key == key) {
            return Ok(());
        }
        if self.pending.len() >= MAX_SUGGESTIONS {
            return Err(Full);
        }
        self.pending.push(Pending {
            id: self.next_id,
            entry,
            key,
            queued: now,
        });
        self.next_id += 1;
        Ok(())
    }

    /// Drops the suggestions whose key `drop` selects.
    pub fn drop_keys(&mut self, drop: impl Fn(&str) -> bool) {
        self.pending.retain(|p| !drop(&p.key));
    }

    pub fn oldest(&self) -> Option<&Pending> {
        self.pending.first()
    }

    pub fn get(&self, id: u64) -> Option<&Pending> {
        self.pending.iter().find(|p| p.id == id)
    }

    pub fn remove(&mut self, id: u64) {
        self.pending.retain(|p| p.id != id);
    }

    pub fn expire(&mut self, now: Instant) {
        self.pending
            .retain(|p| now.saturating_duration_since(p.queued) < SUGGESTION_TTL);
    }

    pub fn next_expiry(&self) -> Option<Instant> {
        self.pending.iter().map(|p| p.queued + SUGGESTION_TTL).min()
    }
}

struct WordSet {
    name: String,
    entries: Vec<DictionaryEntry>,
    expires: Instant,
}

/// Live project word sets, in the order they were first loaded.
#[derive(Default)]
pub struct ProjectWords {
    sets: Vec<WordSet>,
    /// Changes whenever the words do (see [`ProjectWords::generation`]).
    generation: u64,
}

impl ProjectWords {
    /// Loads `entries` as the set `name`, replacing one of that name and
    /// restarting its time. No entries removes the set.
    pub fn set(
        &mut self,
        name: &str,
        entries: Vec<DictionaryEntry>,
        expires: Instant,
    ) -> Result<(), Full> {
        let at = self.sets.iter().position(|s| s.name == name);
        if entries.is_empty() {
            if let Some(i) = at {
                self.sets.remove(i);
                self.generation += 1;
            }
            return Ok(());
        }
        let set = WordSet {
            name: name.to_owned(),
            entries,
            expires,
        };
        match at {
            Some(i) => self.sets[i] = set,
            None if self.sets.len() >= MAX_SETS => return Err(Full),
            None => self.sets.push(set),
        }
        self.generation += 1;
        Ok(())
    }

    /// Removes the set `name`; false if there is none.
    pub fn clear(&mut self, name: &str) -> bool {
        let before = self.sets.len();
        self.sets.retain(|s| s.name != name);
        let removed = self.sets.len() != before;
        if removed {
            self.generation += 1;
        }
        removed
    }

    pub fn expire(&mut self, now: Instant) {
        let before = self.sets.len();
        self.sets.retain(|s| now < s.expires);
        if self.sets.len() != before {
            crate::info!("project words expired");
            self.generation += 1;
        }
    }

    pub fn next_expiry(&self) -> Option<Instant> {
        self.sets.iter().map(|s| s.expires).min()
    }

    pub fn is_empty(&self) -> bool {
        self.sets.is_empty()
    }

    /// Entries loaded, over all sets.
    pub fn count(&self) -> usize {
        self.sets.iter().map(|s| s.entries.len()).sum()
    }

    /// A number that changes whenever the sets do (their words may still be
    /// the same).
    pub fn generation(&self) -> u64 {
        self.generation
    }

    /// `dictionary` with every set's entries added at strength 1, except
    /// those whose key it (or an earlier set) already has: the dictionary's
    /// strength wins.
    pub fn merge(&self, dictionary: &Dictionary) -> Dictionary {
        let mut merged = dictionary.clone();
        let mut keys: Vec<String> = merged.entries.iter().map(DictionaryEntry::key).collect();
        for e in self.sets.iter().flat_map(|s| &s.entries) {
            let key = e.key();
            if !keys.contains(&key) {
                keys.push(key);
                merged.entries.push(e.clone());
            }
        }
        merged
    }
}

/// The entries of a `words` field: pieces separated by `,`, each trimmed
/// and validated like a `dict-add` entry at strength 1. Empty pieces,
/// invalid entries, repeats (by identity key) and entries beyond
/// [`MAX_SET_WORDS`] are skipped; returns the entries and how many were
/// skipped.
pub fn parse_words(words: &str, tokenizer: &Tokenizer) -> (Vec<DictionaryEntry>, u32) {
    let mut entries: Vec<DictionaryEntry> = Vec::new();
    let mut skipped = 0u32;
    for piece in words.split(',') {
        let accepted = rules::validate(piece.trim(), DEFAULT_STRENGTH, tokenizer)
            .ok()
            .filter(|e| {
                entries.len() < MAX_SET_WORDS && !entries.iter().any(|x| x.key() == e.key())
            });
        match accepted {
            Some(e) => entries.push(e),
            None => skipped = skipped.saturating_add(1),
        }
    }
    (entries, skipped)
}

/// The latest agent status report.
#[derive(Clone, Copy, Debug)]
pub struct AgentReport {
    pub counts: AgentCounts,
    pub expires: Instant,
}
