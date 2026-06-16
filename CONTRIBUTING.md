# Contributing to OmniTerm

We welcome contributions! To make the process as smooth as possible, please follow our Git and branching strategy.

## Branching Strategy

This project follows a streamlined **GitHub Flow** strategy:

1. **`main` is protected:** The `main` branch represents the bleeding-edge, compilable source of truth. Direct pushes are not allowed.
2. **Create a branch:** When working on a new feature or bug fix, branch off of `main` using descriptive names:
   - `feature/your-feature-name`
   - `fix/issue-description`
   - `chore/update-dependencies`
3. **Open a Pull Request:** Once your code is ready, open a Pull Request (PR) against the `main` branch.

## Pull Request Guidelines

When you open a PR, our continuous integration (CI) system will automatically build your code and run unit tests. 

- Your PR **must** pass the CI checks before it can be merged. 
- Please write descriptive commit messages and explain the "why" and "what" of your changes in the PR description.
- Wait for a maintainer to review and approve your code.

## Release Process (Maintainers Only)

We do not use a dedicated `release` branch. Versioning and deployments are fully automated.

1. **Version Code:** You never need to touch `versionCode`. It is dynamically calculated based on the total number of Git commits in the repository. Every commit automatically increments the build number.
2. **Version Name:** When you are ready for a major/minor version bump, manually update `versionName` in `app/build.gradle.kts` (e.g. `0.9.0` -> `1.0.0`) and merge that change into `main`.
3. **Trigger the Release:** To push the release to Google Play and GitHub Releases, simply create a Git tag starting with `v` on the `main` branch and push it:
   ```bash
   git tag v1.0.0
   git push origin v1.0.0
   ```
4. GitHub Actions will automatically handle the rest: separating the open-source `.apk` from the proprietary `.aab`, publishing the release to the public GitHub page, and securely deploying the AAB to the Google Play Console internal track.
