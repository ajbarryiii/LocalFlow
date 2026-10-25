//! CPU topology from sysfs (`/sys/devices/system/cpu`): which CPUs are SMT
//! siblings of one physical core, and which cores share an L3 cache.
//!
//! [`Topology::default_cpus`] is the default thread placement: one CPU per
//! physical core (the lowest-numbered allowed sibling), whole L3 domains in
//! order of cache size, at most [`MAX_DEFAULT_THREADS`].

use std::path::Path;

/// Most threads the default placement uses; more were never measured.
pub const MAX_DEFAULT_THREADS: usize = 16;

/// Upper bound on CPU numbers read from sysfs lists (`CPU_SETSIZE`).
const MAX_CPU: usize = 1024;

/// The CPUs this process may run on, ascending (empty if the affinity mask
/// cannot be read).
pub fn allowed_cpus() -> Vec<usize> {
    #[cfg(target_os = "linux")]
    // SAFETY: `set` is a plain bitmask written by the kernel; CPU_ISSET only
    // reads it within CPU_SETSIZE.
    unsafe {
        let mut set: libc::cpu_set_t = std::mem::zeroed();
        if libc::sched_getaffinity(0, std::mem::size_of::<libc::cpu_set_t>(), &mut set) != 0 {
            return Vec::new();
        }
        (0..MAX_CPU).filter(|&c| libc::CPU_ISSET(c, &set)).collect()
    }
    #[cfg(not(target_os = "linux"))]
    Vec::new()
}

/// The physical cores and L3 domains of a set of allowed CPUs.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Topology {
    /// One entry per L3 domain, largest cache first (ties: more cores, then
    /// lower CPU numbers); each lists one CPU per physical core, ascending.
    domains: Vec<L3Domain>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct L3Domain {
    /// One allowed CPU per physical core, ascending.
    pub cores: Vec<usize>,
    /// L3 size in KiB (0 if unknown).
    pub kib: usize,
}

impl Topology {
    /// Reads the topology of `allowed` from `/sys/devices/system/cpu`.
    pub fn read(allowed: &[usize]) -> Topology {
        Topology::from_sysfs(Path::new("/sys/devices/system/cpu"), allowed)
    }

    /// Reads the topology of `allowed` from a sysfs CPU directory. A CPU whose
    /// files are missing or malformed counts as its own core in its own L3
    /// domain of unknown size.
    pub fn from_sysfs(root: &Path, allowed: &[usize]) -> Topology {
        let mut allowed = allowed.to_vec();
        allowed.sort_unstable();
        allowed.dedup();
        let read = |cpu: usize, file: &str| -> Option<String> {
            std::fs::read_to_string(root.join(format!("cpu{cpu}")).join(file)).ok()
        };
        // The physical core of a CPU is named by its lowest sibling, and its
        // L3 domain by the lowest CPU sharing the cache (both over all CPUs,
        // allowed or not, so masks cannot split them).
        let mut cores: Vec<(usize, usize, usize, usize)> = Vec::new(); // (domain, kib, core, cpu)
        for &cpu in &allowed {
            let siblings = read(cpu, "topology/core_cpus_list")
                .or_else(|| read(cpu, "topology/thread_siblings_list"))
                .and_then(|s| parse_list(&s));
            let core = siblings.and_then(|s| s.first().copied()).unwrap_or(cpu);
            let (domain, kib) = l3(root, cpu).unwrap_or((cpu, 0));
            cores.push((domain, kib, core, cpu));
        }
        // The lowest allowed CPU of each core (`allowed` is ascending).
        let mut seen = std::collections::HashSet::new();
        cores.retain(|&(_, _, core, _)| seen.insert(core));
        let mut domains: Vec<(usize, L3Domain)> = Vec::new();
        for (domain, kib, _, cpu) in cores {
            match domains.iter_mut().find(|(d, _)| *d == domain) {
                Some((_, d)) => d.cores.push(cpu),
                None => domains.push((
                    domain,
                    L3Domain {
                        cores: vec![cpu],
                        kib,
                    },
                )),
            }
        }
        let mut domains: Vec<L3Domain> = domains.into_iter().map(|(_, d)| d).collect();
        domains.sort_by(|a, b| {
            (b.kib, b.cores.len())
                .cmp(&(a.kib, a.cores.len()))
                .then(a.cores[0].cmp(&b.cores[0]))
        });
        Topology { domains }
    }

    /// L3 domains, largest cache first.
    pub fn domains(&self) -> &[L3Domain] {
        &self.domains
    }

    /// One CPU per physical core, domain by domain in [`Self::domains`] order.
    pub fn physical_cores(&self) -> Vec<usize> {
        self.domains
            .iter()
            .flat_map(|d| d.cores.iter().copied())
            .collect()
    }

    /// The default placement: [`Self::physical_cores`], at most
    /// [`MAX_DEFAULT_THREADS`].
    pub fn default_cpus(&self) -> Vec<usize> {
        let mut cpus = self.physical_cores();
        cpus.truncate(MAX_DEFAULT_THREADS);
        cpus
    }
}

/// The L3 domain (lowest CPU sharing the cache) and size of `cpu`'s L3.
fn l3(root: &Path, cpu: usize) -> Option<(usize, usize)> {
    let cache = root.join(format!("cpu{cpu}/cache"));
    for entry in std::fs::read_dir(&cache).ok()?.flatten() {
        let dir = entry.path();
        let read = |f: &str| std::fs::read_to_string(dir.join(f)).ok();
        if read("level").as_deref().map(str::trim) != Some("3") {
            continue;
        }
        let shared = parse_list(&read("shared_cpu_list")?)?;
        let kib = read("size").and_then(|s| parse_size_kib(&s)).unwrap_or(0);
        return Some((*shared.first()?, kib));
    }
    None
}

/// `"1024K"` or `"96M"` in KiB.
fn parse_size_kib(s: &str) -> Option<usize> {
    let s = s.trim();
    let (num, mult) = match s.as_bytes().last()? {
        b'K' => (&s[..s.len() - 1], 1),
        b'M' => (&s[..s.len() - 1], 1024),
        b'G' => (&s[..s.len() - 1], 1024 * 1024),
        _ => (s, 1),
    };
    num.parse::<usize>().ok()?.checked_mul(mult)
}

/// A sysfs CPU list such as `"0-7,16-23"`, ascending and deduplicated;
/// `None` if malformed, empty or past `CPU_SETSIZE`.
pub fn parse_list(s: &str) -> Option<Vec<usize>> {
    let mut out = Vec::new();
    for part in s.trim().split(',') {
        let num = |v: &str| v.trim().parse::<usize>().ok().filter(|&c| c < MAX_CPU);
        match part.split_once('-') {
            Some((a, b)) => {
                let (a, b) = (num(a)?, num(b)?);
                if a > b {
                    return None;
                }
                out.extend(a..=b);
            }
            None => out.push(num(part)?),
        }
    }
    out.sort_unstable();
    out.dedup();
    (!out.is_empty()).then_some(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    /// One CPU's thread siblings and (L3 shared list, L3 size); `None` leaves
    /// the files out.
    type FakeCpu<'a> = (Option<&'a str>, Option<(&'a str, &'a str)>);

    /// A synthetic sysfs CPU directory, removed on drop.
    struct Sysfs(PathBuf);

    impl Sysfs {
        fn new(name: &str, cpus: &[FakeCpu]) -> Sysfs {
            let root =
                std::env::temp_dir().join(format!("lf-cpu-topology-{name}-{}", std::process::id()));
            let _ = std::fs::remove_dir_all(&root);
            for (i, (siblings, l3)) in cpus.iter().enumerate() {
                let cpu = root.join(format!("cpu{i}"));
                std::fs::create_dir_all(cpu.join("topology")).unwrap();
                if let Some(s) = siblings {
                    std::fs::write(cpu.join("topology/thread_siblings_list"), s).unwrap();
                }
                for (index, level) in [(0, "1"), (2, "2")] {
                    let dir = cpu.join(format!("cache/index{index}"));
                    std::fs::create_dir_all(&dir).unwrap();
                    std::fs::write(dir.join("level"), level).unwrap();
                    std::fs::write(dir.join("shared_cpu_list"), siblings.unwrap_or("0")).unwrap();
                }
                if let Some((shared, size)) = l3 {
                    let dir = cpu.join("cache/index3");
                    std::fs::create_dir_all(&dir).unwrap();
                    std::fs::write(dir.join("level"), "3\n").unwrap();
                    std::fs::write(dir.join("shared_cpu_list"), format!("{shared}\n")).unwrap();
                    std::fs::write(dir.join("size"), format!("{size}\n")).unwrap();
                }
            }
            Sysfs(root)
        }
    }

    impl Drop for Sysfs {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    /// Two 4-core CCDs with SMT, the second with the larger L3 (CPU `c` and
    /// `c + 8` are siblings).
    fn two_ccds(name: &str) -> Sysfs {
        let siblings: Vec<String> = (0..16)
            .map(|c| format!("{},{}", c % 8, c % 8 + 8))
            .collect();
        let cpus: Vec<FakeCpu> = siblings
            .iter()
            .enumerate()
            .map(|(c, s)| {
                let l3 = if c % 8 < 4 {
                    ("0-3,8-11", "32768K")
                } else {
                    ("4-7,12-15", "98304K")
                };
                (Some(s.as_str()), Some(l3))
            })
            .collect();
        Sysfs::new(name, &cpus)
    }

    #[test]
    fn one_cpu_per_core_largest_cache_first() {
        let fs = two_ccds("smt");
        let all: Vec<usize> = (0..16).collect();
        let t = Topology::from_sysfs(&fs.0, &all);
        assert_eq!(
            t.domains(),
            [
                L3Domain {
                    cores: vec![4, 5, 6, 7],
                    kib: 98304
                },
                L3Domain {
                    cores: vec![0, 1, 2, 3],
                    kib: 32768
                },
            ]
        );
        assert_eq!(t.physical_cores(), [4, 5, 6, 7, 0, 1, 2, 3]);
        assert_eq!(t.default_cpus(), t.physical_cores());
    }

    #[test]
    fn the_affinity_mask_picks_the_siblings() {
        let fs = two_ccds("mask");
        // Only the second sibling of cores 1 and 5, both siblings of core 2,
        // nothing of the others.
        let t = Topology::from_sysfs(&fs.0, &[13, 9, 2, 10]);
        assert_eq!(t.physical_cores(), [13, 2, 9]);
        assert_eq!(t.domains().len(), 2);
    }

    #[test]
    fn missing_files_make_each_cpu_its_own_core() {
        let fs = Sysfs::new("bare", &[(None, None), (None, None), (Some("2"), None)]);
        let t = Topology::from_sysfs(&fs.0, &[0, 1, 2, 7]);
        assert_eq!(t.physical_cores(), [0, 1, 2, 7]);
        assert!(t.domains().iter().all(|d| d.kib == 0 && d.cores.len() == 1));
    }

    #[test]
    fn default_placement_is_capped() {
        let cpus: Vec<FakeCpu> = (0..40).map(|_| (None, Some(("0-39", "65536K")))).collect();
        let fs = Sysfs::new("many", &cpus);
        let all: Vec<usize> = (0..40).collect();
        let t = Topology::from_sysfs(&fs.0, &all);
        assert_eq!(t.physical_cores().len(), 40);
        assert_eq!(
            t.default_cpus(),
            (0..MAX_DEFAULT_THREADS).collect::<Vec<_>>()
        );
    }

    #[test]
    fn lists_and_sizes_parse() {
        assert_eq!(
            parse_list("0-3,8,10-11\n"),
            Some(vec![0, 1, 2, 3, 8, 10, 11])
        );
        assert_eq!(parse_list("5,1,5"), Some(vec![1, 5]));
        for bad in ["", "3-1", "a", "1,,2", "0-2000"] {
            assert_eq!(parse_list(bad), None, "{bad:?}");
        }
        assert_eq!(parse_size_kib("98304K\n"), Some(98304));
        assert_eq!(parse_size_kib("32M"), Some(32768));
        assert_eq!(parse_size_kib("x"), None);
    }
}
