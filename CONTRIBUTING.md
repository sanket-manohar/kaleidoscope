# Contributing to kaleidoscope

Thank you for helping to improve kaleidoscope.

## Before you start
* Search the existing issues first. For larger changes, open an issue to discuss the idea before writing code.
* Never include API keys, real prompts or personal data in issues, tests or pull requests.

## Development setup
```sh
git clone https://github.com/sanket-manohar/kaleidoscope.git
cd kaleidoscope
flutter pub get
flutter test
```
The `example/` app runs without any API keys: `cd example && flutter run`.

## Before opening a pull request
```sh
dart format .
flutter analyze
flutter test
```
* Keep changes focused, and add tests for new behaviour.
* Public APIs need dartdoc comments.
* Update `CHANGELOG.md` for user-facing changes.

## Licence
By contributing, you agree that your contribution is licensed under the
[BSD 3-Clause License](LICENSE) and that you have the right to submit it.
See also section 21 of the [Terms and Conditions](TERMS.md).
