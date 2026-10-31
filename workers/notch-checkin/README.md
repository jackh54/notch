# notch-checkin

Shows which versions of the Agent Notch fork are installed. The app sends a random install ID, its version and its build once a day. There is no setting to turn this off; Settings > Agents > Version check-in describes it. Releases up to 2.7.3-agents.3 have a toggle that deletes the install here.

Sparkle updates don't pass through this Worker, so updates keep working when it is down.

## Stored

`install_id`, `version`, `build`, `first_seen` and `last_seen`. No names or IP addresses, and invocation logs are off. Installs that go quiet for 180 days are removed.

## Deploying

Live at `notch.pandascript.dev` on the Jack account. `STATS_TOKEN` is a Worker secret, with a copy in the login Keychain.

```bash
npm install
npm run deploy
```

`npm run deploy` runs the config guard, typecheck and tests, applies migrations, then deploys. Don't use a bare `wrangler deploy`.

## Viewing installs

```bash
curl -H "Authorization: Bearer $(security find-generic-password -a jackh54-notch -s notch-checkin-stats -w)" https://notch.pandascript.dev/stats
```

The result lists installs per version, plus each install by the first 8 characters of its ID. The app shows the same short ID in Settings, so a friend can tell you which one is theirs.

## Local testing

```bash
npm test
```

To run the app's real code against a local Worker, start `wrangler dev` and run a Debug build with `NOTCH_CHECKIN_URL` set and the `--check-in-test` flag.
