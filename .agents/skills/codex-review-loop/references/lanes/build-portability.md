# Build And Portability Lane

Review build, package, resource, and CI changes for:

- Swift 5.9.2 compatibility for the Linux Agent and Hub.
- macOS-only imports or APIs leaking into cross-platform package targets.
- CSQLite availability, conditional dependencies, linker assumptions, and
  platform guards.
- Vapor dependencies remaining isolated to the Hub package.
- XcodeGen source/resource membership, build settings, generated project drift,
  and case-sensitive paths.
- Package resolution or lockfile changes that are missing, unintended, or
  inconsistent across root, Hub, and Xcode workspaces.
- CI jobs no longer exercising required builds or tests.

Prefer `project.yml` plus regeneration over direct project-file edits.
