//! Simple text normalization and word-level edit counts, shared by the
//! evaluation binaries.

/// Lowercase, keep letters/digits/apostrophes inside words, everything else a space.
pub fn normalize(s: &str) -> Vec<String> {
    let lower = s.to_lowercase();
    let cleaned: String = lower
        .chars()
        .map(|c| {
            if c.is_alphanumeric() || c == '\'' {
                c
            } else {
                ' '
            }
        })
        .collect();
    cleaned
        .split_whitespace()
        .map(|w| w.trim_matches('\'').to_owned())
        .filter(|w| !w.is_empty())
        .collect()
}

/// Word-level alignment counts.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Errors {
    pub sub: usize,
    pub del: usize,
    pub ins: usize,
}

impl Errors {
    pub fn total(self) -> usize {
        self.sub + self.del + self.ins
    }

    pub fn add(&mut self, o: Errors) {
        self.sub += o.sub;
        self.del += o.del;
        self.ins += o.ins;
    }
}

/// Minimum-edit alignment of `hyp` against `reference`, with S/D/I counts.
#[allow(clippy::needless_range_loop)]
pub fn align(reference: &[String], hyp: &[String]) -> Errors {
    let (n, m) = (reference.len(), hyp.len());
    let mut d = vec![vec![(0usize, Errors::default()); m + 1]; n + 1];
    for i in 1..=n {
        d[i][0] = (
            i,
            Errors {
                del: i,
                ..Default::default()
            },
        );
    }
    for j in 1..=m {
        d[0][j] = (
            j,
            Errors {
                ins: j,
                ..Default::default()
            },
        );
    }
    for i in 1..=n {
        for j in 1..=m {
            let same = reference[i - 1] == hyp[j - 1];
            let (c, mut e) = d[i - 1][j - 1];
            let mut best = (c + usize::from(!same), {
                e.sub += usize::from(!same);
                e
            });
            let (c, mut e) = d[i - 1][j];
            if c + 1 < best.0 {
                e.del += 1;
                best = (c + 1, e);
            }
            let (c, mut e) = d[i][j - 1];
            if c + 1 < best.0 {
                e.ins += 1;
                best = (c + 1, e);
            }
            d[i][j] = best;
        }
    }
    d[n][m].1
}

pub fn edits(reference: &[String], hyp: &[String]) -> usize {
    align(reference, hyp).total()
}

/// Word edits between two raw texts after normalization.
pub fn text_edits(a: &str, b: &str) -> usize {
    edits(&normalize(a), &normalize(b))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wer_basics() {
        let r = normalize("Hello, world! It's fine.");
        assert_eq!(r, vec!["hello", "world", "it's", "fine"]);
        assert_eq!(edits(&r, &normalize("hello word it's fine")), 1);
        assert_eq!(edits(&r, &normalize("")), 4);
        assert_eq!(edits(&normalize(""), &r), 4);
        let e = align(&r, &normalize("hello world"));
        assert_eq!((e.sub, e.del, e.ins), (0, 2, 0));
        let e = align(&r, &normalize("hello big world it's fine"));
        assert_eq!((e.sub, e.del, e.ins), (0, 0, 1));
        let e = align(&r, &normalize("yellow world it's fine"));
        assert_eq!((e.sub, e.del, e.ins), (1, 0, 0));
        // Punctuation and case differences are not word edits.
        assert_eq!(text_edits("Well, yes.", "well yes"), 0);
    }
}
