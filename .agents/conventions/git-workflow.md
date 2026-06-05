# Git Workflow & Contribution

1. Create branches, commits, or PRs only upon explicit user request.
2. Do not commit directly to `main` unless the user explicitly asks for it.
3. Use branch prefixes like `feature/`, `fix/`, `chore/`, or `test/`.
4. Prefer Conventional Commits for commit messages and PR titles:
   `<type>(<scope>): <description>`.
5. Allowed common types: `feat`, `fix`, `docs`, `style`, `refactor`, `perf`,
   `test`, `build`, `ci`, `chore`, `revert`.
6. Always check `git status` and relevant `git diff` before staging, committing,
   pushing, or opening a PR.
7. Preserve unrelated local changes. Do not reset, checkout, or revert files you
   did not intentionally change.

## Remote Branch And Pull Request Safety

- Remote branch deletion is destructive. Never delete remote branches unless
  the user explicitly names the remote branch to delete.
- Branch cleanup means local branches plus `git fetch --prune` by default.
- Before deleting a remote branch, check whether it backs an open PR:

  ```bash
  gh pr list --head <branch> --state open --json number,title,author,url,headRefName,baseRefName
  ```

- If an open PR exists, require explicit confirmation of the repository, branch,
  and PR number before deletion.
- If the PR author is not the current authenticated GitHub user, stop the task,
  report the affected repo/branch/PR/author, and wait for a fresh confirmation
  in a new user response.
- Never close, merge, mark ready/draft, retarget, force-push, delete the head
  branch of, resolve review threads on, or otherwise mutate another person's PR
  without fresh explicit confirmation.

## Typical Explicit Workflow

```bash
git switch -c fix/example
git status --short
git diff
git add <files>
git commit -m "fix(scope): describe the change"
git push -u origin fix/example
```
