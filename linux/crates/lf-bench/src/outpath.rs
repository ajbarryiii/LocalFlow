//! Guards for evaluation outputs, shared by the evaluation binaries: dataset
//! text, hypotheses and caches must never land in a Git work tree.

use std::path::{Path, PathBuf};

fn refuse_inside_git(path: &Path, dir: &Path) -> Result<(), String> {
    if let Some(repo) = dir.ancestors().find(|d| d.join(".git").exists()) {
        return Err(format!(
            "{}: inside the Git work tree {}; write data and results outside any repository",
            path.display(),
            repo.display()
        ));
    }
    Ok(())
}

/// Refuses paths inside a Git work tree (after resolving symbolic links in the
/// parent directory). A symbolic link is refused too, since it could point into
/// a repository; the file is then opened without following links
/// (`create_output`).
pub fn check_output_path(path: &Path) -> Result<(), String> {
    if let Ok(m) = std::fs::symlink_metadata(path)
        && m.file_type().is_symlink()
    {
        return Err(format!(
            "{}: is a symbolic link; refusing to write through it",
            path.display()
        ));
    }
    let parent = match path.parent() {
        Some(p) if !p.as_os_str().is_empty() => p.to_path_buf(),
        _ => PathBuf::from("."),
    };
    let dir = parent
        .canonicalize()
        .map_err(|e| format!("{}: {e}", parent.display()))?;
    refuse_inside_git(path, &dir)
}

/// Refuses `dir` if it resolves (through any symbolic links) to a place inside
/// a Git work tree, then creates it if needed. The nearest existing ancestor
/// is checked first, so nothing is created inside a repository.
#[allow(dead_code)]
pub fn check_output_dir(dir: &Path) -> Result<(), String> {
    let absolute = std::path::absolute(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    let existing = absolute
        .ancestors()
        .find(|a| a.exists())
        .ok_or(format!("{}: no existing ancestor", dir.display()))?;
    let canon = existing
        .canonicalize()
        .map_err(|e| format!("{}: {e}", existing.display()))?;
    refuse_inside_git(dir, &canon)?;
    std::fs::create_dir_all(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    let canon = dir
        .canonicalize()
        .map_err(|e| format!("{}: {e}", dir.display()))?;
    refuse_inside_git(dir, &canon)
}

/// Creates or truncates a checked output file, failing if it is a symbolic link.
/// An existing file is truncated only if it is a regular file with a single
/// link, checked on the opened file itself, so a hard link to a file elsewhere
/// (for example in a repository) is never overwritten.
pub fn create_output(path: &Path) -> Result<std::fs::File, String> {
    use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
    check_output_path(path)?;
    let err = |e: std::io::Error| format!("{}: {e}", path.display());
    let file = std::fs::OpenOptions::new()
        .write(true)
        .create(true)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)
        .map_err(err)?;
    let meta = file.metadata().map_err(err)?;
    if !meta.is_file() || meta.nlink() != 1 {
        return Err(format!(
            "{}: not a regular file with a single link; refusing to overwrite it",
            path.display()
        ));
    }
    file.set_len(0).map_err(err)?;
    Ok(file)
}

/// Writes `bytes` to a checked output file (see [`create_output`]).
#[allow(dead_code)]
pub fn write_output(path: &Path, bytes: &[u8]) -> Result<(), String> {
    use std::io::Write;
    let mut f = create_output(path)?;
    f.write_all(bytes)
        .and_then(|_| f.flush())
        .map_err(|e| format!("{}: {e}", path.display()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn outputs_must_be_outside_git() {
        let base =
            std::env::temp_dir().join(format!("lf-bench-outpath-test-{}", std::process::id()));
        let repo = base.join("repo");
        std::fs::create_dir_all(repo.join(".git")).unwrap();
        std::fs::create_dir_all(repo.join("sub")).unwrap();
        assert!(check_output_path(&repo.join("sub/h.jsonl")).is_err());
        assert!(check_output_path(&repo.join("h.jsonl")).is_err());
        // A worktree's `.git` is a file.
        let wt = base.join("wt");
        std::fs::create_dir_all(&wt).unwrap();
        std::fs::write(wt.join(".git"), "gitdir: elsewhere\n").unwrap();
        assert!(check_output_path(&wt.join("h.jsonl")).is_err());
        let out = base.join("out");
        std::fs::create_dir_all(&out).unwrap();
        assert!(check_output_path(&out.join("h.jsonl")).is_ok());
        assert!(check_output_path(&base.join("missing/h.jsonl")).is_err());
        // Links out of the checked directory are refused, existing or dangling.
        std::fs::write(repo.join("tracked.jsonl"), "keep").unwrap();
        let link = out.join("link.jsonl");
        std::os::unix::fs::symlink(repo.join("tracked.jsonl"), &link).unwrap();
        assert!(check_output_path(&link).is_err());
        assert!(create_output(&link).is_err());
        let dangling = out.join("dangling.jsonl");
        std::os::unix::fs::symlink(repo.join("new.jsonl"), &dangling).unwrap();
        assert!(create_output(&dangling).is_err());
        assert!(!repo.join("new.jsonl").exists());
        assert_eq!(
            std::fs::read_to_string(repo.join("tracked.jsonl")).unwrap(),
            "keep"
        );
        // A hard link to a repository file is not truncated.
        let hard = out.join("hard.jsonl");
        std::fs::hard_link(repo.join("tracked.jsonl"), &hard).unwrap();
        assert!(create_output(&hard).is_err());
        assert!(write_output(&hard, b"x").is_err());
        assert_eq!(
            std::fs::read_to_string(repo.join("tracked.jsonl")).unwrap(),
            "keep"
        );
        // A plain file is created, then truncated on reuse.
        let plain = out.join("h.jsonl");
        std::fs::write(&plain, "old").unwrap();
        drop(create_output(&plain).unwrap());
        assert_eq!(std::fs::read_to_string(&plain).unwrap(), "");
        write_output(&plain, b"new").unwrap();
        assert_eq!(std::fs::read_to_string(&plain).unwrap(), "new");
        drop(create_output(&out.join("new.jsonl")).unwrap());
        assert!(out.join("new.jsonl").is_file());
        // Directories: inside a repository (directly or through a link) is refused.
        assert!(check_output_dir(&repo.join("results")).is_err());
        assert!(!repo.join("results").exists());
        let dir_link = out.join("into-repo");
        std::os::unix::fs::symlink(repo.join("sub"), &dir_link).unwrap();
        assert!(check_output_dir(&dir_link).is_err());
        assert!(check_output_dir(&dir_link.join("deeper")).is_err());
        assert!(check_output_dir(&out.join("results/nested")).is_ok());
        assert!(out.join("results/nested").is_dir());
        std::fs::remove_dir_all(&base).unwrap();
    }
}
