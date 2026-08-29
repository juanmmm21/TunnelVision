# CI workflow (ready to install)

The workflow below is kept here as a document rather than in `.github/workflows/`, because
pushing a file under that path requires a credential with the `workflow` scope. To turn CI on,
create `.github/workflows/ci.yml` with this content — either by pushing it with a token that has
the `workflow` scope, or by adding the file through GitHub's web editor, which needs no token.

It runs two jobs: the unit tests on a Simulator, and an authorship check.

The packet tunnel extension is device-only, so CI builds and runs the **unit tests** only. Two
details of the test invocation are load-bearing and were verified before this was written:

- **No `CODE_SIGNING_ALLOWED=NO`.** The test bundle runs inside the app (`TEST_HOST` in
  `project.yml`) so that tests inherit its Keychain entitlements. Disabling signing removes them,
  `SecItemAdd` returns `errSecMissingEntitlement` (-34018), and the five `LoopbackTLSServerSession`
  tests fail. Ad-hoc Simulator signing keeps the entitlements and needs no developer account —
  the full suite of 1710 tests passes with `DEVELOPMENT_TEAM` empty.
- **The simulator is resolved, not hard-coded.** Runner images change which iPhone models they
  carry, and a destination that does not exist fails with an error that does not say so.

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:

jobs:
  test:
    name: Build & unit tests (Simulator)
    runs-on: macos-latest

    steps:
      - uses: actions/checkout@v4

      - name: Install XcodeGen
        run: brew install xcodegen

      # El .xcodeproj no se versiona: se genera de project.yml en cada build.
      - name: Generate project
        run: xcodegen generate

      # El nombre del simulador cambia con la imagen del runner, así que se resuelve en vez de
      # fijarse: un destino que no existe falla con un error que no dice que el problema es ese.
      - name: Pick a simulator
        id: sim
        run: |
          name=$(xcrun simctl list devices available --json \
            | python3 -c "import json,sys;d=json.load(sys.stdin)['devices'];print(next(x['name'] for v in d.values() for x in v if x['name'].startswith('iPhone')))")
          echo "Using $name"
          echo "name=$name" >> "$GITHUB_OUTPUT"

      # Sin `CODE_SIGNING_ALLOWED=NO`, y no es un descuido: el bundle de tests corre dentro de la
      # app (TEST_HOST) para heredar sus entitlements de llavero, y desactivar la firma se los quita
      # —SecItemAdd devuelve errSecMissingEntitlement (-34018) y los tests de TLS caen—. La firma
      # ad-hoc del simulador sí los conserva y no necesita cuenta de desarrollador.
      - name: Unit tests
        run: |
          xcodebuild test \
            -scheme TunnelVision \
            -destination "platform=iOS Simulator,name=${{ steps.sim.outputs.name }}" \
            -only-testing:TunnelVisionTests \
            DEVELOPMENT_TEAM="" \
            CODE_SIGN_IDENTITY="-" \
            CODE_SIGN_STYLE=Manual \
            CODE_SIGNING_REQUIRED=NO

  authorship:
    name: Verify authorship
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - name: Single author, no co-author trailers
        run: |
          test "$(git log --format='%B' | grep -c 'Co-authored-by')" -eq 0
          test -z "$(git log --format='%an <%ae>' | sort -u | grep -v '^juanmmm21 <martoscuevasjuan@gmail.com>$')"
```
