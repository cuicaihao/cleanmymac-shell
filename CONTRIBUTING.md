# Contributing

Thanks for helping improve `mac-cleaner`. This project is intentionally small, so changes should stay focused and easy to review.

## Development

Use short-lived branches for changes. Keep `main` releasable. Releases are created only from version tags.

Run the local checks before opening a pull request:

```bash
make check
```

`make check` runs Bash syntax validation and ShellCheck when ShellCheck is available.

Useful manual smoke checks:

```bash
./mac-cleaner.sh --version
./mac-cleaner.sh --help
./mac-cleaner.sh --dry-run --verbose
```

## Versioning

Releases use semantic versioning: `MAJOR.MINOR.PATCH`.

- Patch releases fix bugs without changing expected behavior.
- Minor releases add backward-compatible features or options.
- Major releases are for breaking CLI or behavior changes.

The runtime version lives in `mac-cleaner.sh`:

```bash
VERSION="X.Y.Z"
```

Release tags use the same version with a `v` prefix:

```bash
vX.Y.Z
```

## Release Process

To publish a release:

1. Update `VERSION` in `mac-cleaner.sh`.
2. Commit the change.
3. Push the commit to `main`.
4. Push a matching tag:

```bash
version=X.Y.Z
git tag "v${version}"
git push origin "v${version}"
```

GitHub Actions verifies the tag against the script version, runs checks, packages the executable, and creates a GitHub Release.

The release uploads:

- `mac-cleaner.tar.gz`: stable asset name for the latest-release install URL.
- `mac-cleaner-vX.Y.Z.tar.gz`: versioned asset name for pinned installs.

## Continuous Integration

CI runs on pull requests and pushes to `main`. It skips documentation-only and image-only changes.

Release automation runs only for tags matching `v*.*.*`.
