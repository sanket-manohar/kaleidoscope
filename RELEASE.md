# Releasing kaleidoscope 1.0.0 from the terminal

Every step below runs in a terminal. Only a few optional extras need a browser
(they are listed at the end), because pub.dev and GitHub have no command for
them.

Commands are for macOS and Linux. On Windows, use Git Bash, or PowerShell
with the same commands.

---

## 0. One-time setup

### Install the tools

```bash
# macOS (Homebrew)
brew install git gh

# Ubuntu / Debian
sudo apt install git gh

# Windows
winget install Git.Git GitHub.cli
```

Flutter 3.35 or newer must also be installed:

```bash
flutter --version
```

### Sign in to GitHub from the terminal

```bash
gh auth login
```

Choose **GitHub.com**, then **HTTPS**, then **Login with a web browser**, and
enter the code it shows. Check:

```bash
gh auth status
```

It should say `Logged in to github.com account sanket-manohar`.

---

## 1. Unpack the project

```bash
cd ~/Projects            # or any folder you like
unzip kaleidoscope-v1.0.0.zip
cd kaleidoscope
```

The folder already contains a git repository with one commit and the
`v1.0.0` tag:

```bash
git log --oneline        # Release kaleidoscope 1.0.0
git tag                  # v1.0.0
```

### Check the commit author

```bash
git log -1 --format='%an <%ae>'
```

If GitHub's **"Block command line pushes that expose my email"** setting is
on, the push in step 3 is refused. In that case, use your GitHub private email
(find it with `gh api user/emails --jq '.[].email'`; it ends in
`@users.noreply.github.com`) and rewrite the commit and tag:

```bash
git config user.name  "Sanket Santosh Vidya Manohar"
git config user.email "<id>+sanket-manohar@users.noreply.github.com"
git commit --amend --reset-author --no-edit
git tag -f -a v1.0.0 -m "kaleidoscope 1.0.0"
```

---

## 2. Final local checks

```bash
flutter pub get
dart format --output=none --set-exit-if-changed .
flutter analyze
flutter test
(cd example && flutter pub get && flutter analyze)
flutter pub publish --dry-run
```

Everything must pass, and the last command must end with
`Package has 0 warnings.`

`flutter pub get` creates `pubspec.lock`, which git ignores, so the working
tree stays clean. Check with `git status`.

---

## 3. Create the GitHub repository and push

This creates `github.com/sanket-manohar/kaleidoscope`, links it as `origin` and
pushes the `main` branch in one command:

```bash
gh repo create sanket-manohar/kaleidoscope \
  --public \
  --source=. \
  --remote=origin \
  --description "See every AI call your Flutter app makes: tokens, cost, latency and errors by module, page and section." \
  --homepage "https://sanket-manohar.github.io/kaleidoscope" \
  --push
```

Do **not** push the `v1.0.0` tag yet (see step 6).

Add topics, and turn on Discussions and private vulnerability reporting:

```bash
gh repo edit sanket-manohar/kaleidoscope \
  --add-topic flutter,dart,ai,llm,analytics,monitoring,tokens,openai,gemini,flutter-package \
  --enable-discussions

gh api -X PUT repos/sanket-manohar/kaleidoscope/private-vulnerability-reporting
```

Watch the CI run (format, analyze, tests, publish dry run):

```bash
gh run watch $(gh run list --workflow CI --limit 1 --json databaseId --jq '.[0].databaseId')
```

---

## 4. Publish the website on GitHub Pages

Turn on Pages, deployed by GitHub Actions:

```bash
gh api -X POST repos/sanket-manohar/kaleidoscope/pages -f build_type=workflow
```

Run the deploy workflow and wait for it:

```bash
gh workflow run "Deploy website"
sleep 5
gh run watch $(gh run list --workflow "Deploy website" --limit 1 --json databaseId --jq '.[0].databaseId')
```

Check the address:

```bash
gh api repos/sanket-manohar/kaleidoscope/pages --jq .html_url
curl -sI https://sanket-manohar.github.io/kaleidoscope/ | head -1   # HTTP/2 200
```

From now on, every push that changes `website/` redeploys it automatically.

---

## 5. Publish to pub.dev

pub.dev requires the first version of a package to be uploaded by hand.

```bash
flutter pub publish
```

1. Read the summary of files and type `y`.
2. The first time, it prints a sign-in link. Open it, sign in with the
   Google account that owns the **sanketmanohar.com** publisher, and allow
   access. The terminal continues by itself.
3. It ends with
   `Successfully uploaded https://pub.dev/packages/kaleidoscope version 1.0.0.`

Check it from the terminal:

```bash
curl -s https://pub.dev/api/packages/kaleidoscope | head -c 300; echo
```

Scoring takes 10 to 30 minutes. Then:

```bash
curl -s https://pub.dev/api/packages/kaleidoscope/score
```

`grantedPoints` should be `160`.

---

## 6. Push the tag and create the GitHub release

The repository has a workflow that publishes to pub.dev whenever a `v*` tag is
pushed. Version 1.0.0 is already on pub.dev, so switch that workflow off for
this one tag to avoid a failed run:

```bash
gh workflow disable "Publish to pub.dev"
git push origin v1.0.0
```

Create the release with the 1.0.0 notes from the changelog, and attach the
guide:

```bash
awk '/^## 1.0.0/{f=1;next} /^## /{f=0} f' CHANGELOG.md > /tmp/kaleidoscope-notes.md

gh release create v1.0.0 \
  --verify-tag \
  --title "kaleidoscope 1.0.0" \
  --notes-file /tmp/kaleidoscope-notes.md \
  doc/kaleidoscope-guide.pdf
```

Switch the workflow back on for future releases:

```bash
gh workflow enable "Publish to pub.dev"
```

---

## 7. Later versions

Create the `pub.dev` environment that the publish workflow uses:

```bash
gh api -X PUT repos/sanket-manohar/kaleidoscope/environments/pub.dev
```

After the browser extras 1 and 2 at the end of this file, every new version
is released fully from the terminal:

```bash
# 1. In pubspec.yaml, set: version: 1.0.1
# 2. At the top of CHANGELOG.md, add a "## 1.0.1" section
flutter pub publish --dry-run
git add -A
git commit -m "Release 1.0.1"
git tag -a v1.0.1 -m "kaleidoscope 1.0.1"
git push origin main v1.0.1

gh run watch $(gh run list --workflow "Publish to pub.dev" --limit 1 --json databaseId --jq '.[0].databaseId')

awk '/^## 1.0.1/{f=1;next} /^## /{f=0} f' CHANGELOG.md > /tmp/notes.md
gh release create v1.0.1 --verify-tag --title "kaleidoscope 1.0.1" \
  --notes-file /tmp/notes.md doc/kaleidoscope-guide.pdf
```

If you prefer to always publish by hand, skip browser extra 2. Run
`gh workflow disable "Publish to pub.dev"` once, and use `flutter pub publish`
before pushing each tag.

---

## 8. Final check

```bash
gh repo view sanket-manohar/kaleidoscope --web
open https://sanket-manohar.github.io/kaleidoscope/   # xdg-open on Linux, start on Windows
open https://pub.dev/packages/kaleidoscope
```

---

## Browser-only extras (one time, about two minutes)

pub.dev and GitHub have no terminal command for these.

1. **Move the package to your verified publisher.** Open
   <https://pub.dev/packages/kaleidoscope/admin>. Under
   **Transfer to publisher**, pick `sanketmanohar.com` and confirm. The package
   then shows the verified checkmark and is listed at
   <https://pub.dev/publishers/sanketmanohar.com/packages>.
2. **Enable automated publishing** (only if you want step 7 to publish
   automatically). On the same admin page, under **Automated publishing**,
   click **Enable publishing from GitHub Actions** and enter:
   - Repository: `sanket-manohar/kaleidoscope`
   - Tag pattern: `v{{version}}`
   - Require GitHub Actions environment: `pub.dev`
3. **Social preview image** (optional). In the repository, open
   **Settings → General → Social preview** and upload
   `doc/brand/png/banner-dark@2x.png`.

---

## Troubleshooting

| Problem | Fix |
| --- | --- |
| `gh repo create` says the name already exists | Run `git remote add origin https://github.com/sanket-manohar/kaleidoscope.git` and then `git push -u origin main`. |
| Push refused because of email privacy | Follow the email fix in step 1. |
| The `pages` API returns 409 | Pages is already on. Continue with `gh workflow run "Deploy website"`. |
| `flutter pub publish` says the version already exists | Bump `version` in `pubspec.yaml` and add a changelog section. |
| The publish workflow fails with "not authorized" | Browser extra 2 is not done, or the tag does not match `v{{version}}`. |
| The website shows 404 right after deploy | Wait a minute and reload. The first deploy can take a little time. |

---

## Project details

| What | Value |
| --- | --- |
| Repository | https://github.com/sanket-manohar/kaleidoscope |
| Documentation website | https://sanket-manohar.github.io/kaleidoscope |
| Package | https://pub.dev/packages/kaleidoscope |
| Publisher | https://pub.dev/publishers/sanketmanohar.com/packages |
| Personal website | https://sanketmanohar.com/ |
| VS Code Marketplace | https://marketplace.visualstudio.com/publishers/sanket-manohar |
| YouTube | https://www.youtube.com/@sanketmanoharstudio |
| Instagram | https://www.instagram.com/sanketmanoharstudio/ |
| Licence | BSD 3-Clause |
| Terms | `TERMS.md` (free experimental project, laws of India, courts at Mumbai) |

The Terms are a strong starting point, but they are not legal advice. Before
any commercial use, have a lawyer read them.
