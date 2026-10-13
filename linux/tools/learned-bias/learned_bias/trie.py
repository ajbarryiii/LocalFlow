"""A Python port of the parts of `lf_cpu::bias::BiasGraph` the training side
needs: the trie in the graph's own state order, failure links, `step` and
`candidates`. Used for synthetic fixtures and tests; real training reads the
trie and candidates from the shards that Rust writes.
"""

from collections import deque

ROOT = 0


class BiasTrie:
    """Aho-Corasick automaton over token ids, numbered exactly as BiasGraph:
    states in creation order while inserting `phrases` in order."""

    def __init__(self, phrases, tokens=1024):
        kids = [dict()]
        end = [False]
        for i, p in enumerate(phrases):
            if len(p) == 0:
                raise ValueError(f"phrase {i} is empty")
            s = 0
            for t in p:
                t = int(t)
                if not 0 <= t < tokens:
                    raise ValueError(f"phrase {i}: token {t} out of range")
                c = kids[s].get(t)
                if c is None:
                    c = len(kids)
                    kids[s][t] = c
                    kids.append(dict())
                    end.append(False)
                s = c
            end[s] = True
        self._finish(kids, end)

    @classmethod
    def from_tree(cls, token, parent, is_end):
        """The automaton of a trie given as arrays in state order (root 0,
        parent -1; the root's token is ignored), e.g. a shard's trie."""
        n = len(parent)
        kids = [dict() for _ in range(n)]
        for c in range(1, n):
            p, t = int(parent[c]), int(token[c])
            if not 0 <= p < c or t in kids[p]:
                raise ValueError(f"node {c}: bad parent {p} or duplicate edge {t}")
            kids[p][t] = c
        self = cls.__new__(cls)
        self._finish(kids, [bool(e) for e in is_end])
        return self

    def _finish(self, kids, end):
        n = len(kids)
        self._kids = kids
        self.children = [sorted(k.items()) for k in kids]
        self.end = end
        self.parent = [-1] * n
        self.edge = [None] * n
        self.depth = [0] * n
        self.fail = [ROOT] * n
        queue = deque([ROOT])
        while queue:
            s = queue.popleft()
            for t, c in self.children[s]:
                self.depth[c] = self.depth[s] + 1
                self.parent[c] = s
                self.edge[c] = t
                self.fail[c] = ROOT if s == ROOT else self._next(self.fail[s], t)
                queue.append(c)

    def states(self):
        return len(self.children)

    def _child(self, s, t):
        return self._kids[s].get(t)

    def _next(self, s, t):
        f = s
        while True:
            m = self._child(f, t)
            if m is not None:
                return m
            if f == ROOT:
                return ROOT
            f = self.fail[f]

    def step(self, state, token):
        """Destination state after non-blank `token` at `state`."""
        return self._next(state, int(token))

    def candidates(self, state):
        """Every (token, dest) with step(state, token) != ROOT, sorted by
        token; the deepest destination on the failure chain wins."""
        out = {}
        s = state
        while True:
            for t, c in self.children[s]:
                out.setdefault(t, c)
            if s == ROOT:
                break
            s = self.fail[s]
        return sorted(out.items())

    def override_table(self):
        """CONTRACT-2 §4 encoding: the root's candidates, plus per state the
        rows absent from the root set or with a different destination.
        Returns (root_rows, offsets [N+1], rows)."""
        root = self.candidates(ROOT)
        root_map = dict(root)
        offsets = [0]
        rows = []
        for s in range(self.states()):
            for t, d in self.candidates(s):
                if root_map.get(t) != d:
                    rows.append((t, d))
            offsets.append(len(rows))
        return root, offsets, rows
