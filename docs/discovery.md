# macOS 27 provider discovery investigation

Observed on macOS 27 build 26A428, Xcode 27 build 27A266a, September 14, 2026.

`Claude.app` hosts the Swift bridge on `127.0.0.1:17839`; a live request returned `Claude bridge works`. Clicking the app's **Enable in Spotlight…** button completed successfully, and both Apple processes loaded `Claude.app/Contents/Resources/DiscoveryOverride.dylib`. A provider query reports **Claude** as installed and available. A full native Spotlight conversation with the current app build remains a separate manual check.

## Confirmed findings

1. The extension's generated metadata correctly advertises `com.apple.link.systemProtocol.AgentIntent` with feature mask 5 (Siri and Writing Tools).
2. PlugInKit registers the extension. Both App Intents' metadata index and Siri's ToolKit database contain `dev.goldengate.Claude.ClaudeIntent`.
3. `linkd` logs `Could not create application record ... -10814` while checking the extension. Its final index status is nevertheless `processed`, with the intent and system protocol preserved. That message alone is not an indexing failure.
4. Siri's `GenerativePartnerService.ExternalProviderService` separately checks the containing app's model-delegation entitlement. The app and extension now both carry it.
5. This OS build also filters provider discovery using `os_variant_has_internal_ui` and the `useExpandedDiscovery` preference. With the normal checks, its installed/available lists return only ChatGPT. An isolated diagnostic process with internal UI and expanded discovery enabled returns Claude as installed, available, not out of date, and not hidden.
6. A temporary override in Siri AI and `generativeexperiencesd` produced logs showing Claude available. The provider appeared in Spotlight's **Ask…** context menu. Siri's own menu and the Settings extension still differed, demonstrating separate client discovery/caching paths.
7. The native enablement flow and a real request succeeded. After selecting Claude in Spotlight and accepting **Turn On**, the user sent `ping` and received `pong`. Local logs at 22:07 CEST show macOS granting `kTCCServiceExternalAIVisibleToSystem` for the host app, invoking `ClaudeIntent.perform()`, completing its localhost request with HTTP 200 in about six seconds, and finishing the intent without error. No programmatic consent override was used.

A reboot does not remove this build's discovery filter. Disabling SIP and AMFI is insufficient by itself on this tested build.

## Experimental runtime shim

`hooks/DiscoveryOverride.c` interposes the internal-UI query only for the GenerativePartnerService subsystem and the empty subsystem used by its preferences path. The `-useExpandedDiscovery YES` argument supplies the process-local preference. It does not grant model-provider consent, disable entitlement checks, or change Apple binaries, boot arguments, or launch plists.

The shim includes arm64 and arm64e slices. This is a beta-specific research tool, not a supported installation mechanism.

```sh
# Explicit development experiment; sudo is needed for launchctl debug:
./scripts/discovery-session.sh start

# Restore normal launches:
./scripts/discovery-session.sh stop
```

`launchctl debug` configures the next invocation only. The injected library remains loaded in that running process until it exits. The stop command restarts the two affected services with their normal settings. A reboot also ends the temporary session. Do not use a global `launchctl setenv DYLD_INSERT_LIBRARIES` for this experiment.

The app's **Enable in Spotlight…** button and the command-line wrapper use the same bundled `discovery-control.sh`. It backs up provider preferences under `~/Library/Application Support/dev.goldengate.Claude/DiscoveryBackups/` and deletes only the generated `externalProviders` and `externalProvidersSHA256Hash` cache keys before restarting. Consent is preserved. Both start and stop also reset Spotlight's `CampoRemoteService`, which macOS recreates on demand. Run these commands between requests: they close the active Siri/Spotlight UI.

For the tested path, press **Command-Space**, right-click the input, choose **Ask… → Claude**, and submit a short text prompt. If prompted, complete both the Siri confirmation and the native provider **Turn On** sheet. Keep the temporary discovery session running through consent and the request. During troubleshooting, restoring stock processes while a cached Claude entry remained caused an **Unavailable** sheet and the menu entry to disappear as the list refreshed.

The native onboarding sheet showed a placeholder symbol. This example has no app icon asset, and the exact artwork lookup used by this sheet has not been verified. The placeholder did not prevent consent or execution. Its generic “create images” copy is supplied by macOS and does not describe this example's text-only implementation.

## Known issue during the experiment

The user reported being unable to type in Spotlight while these changes and UI automation were being tested. Causality has not been established. UI automation was stopped, both modified Siri processes were restored, and Spotlight's `CampoRemoteService` was force-stopped after ignoring SIGTERM. Avoid treating this runtime shim as ready for daily use until input stability and all discovery clients are tested.

## What is still unverified

- Writing Tools runtime behavior.
- A reliable, stable override covering all UI and service discovery clients.
- Voice routing and selecting the provider from Siri's separate Ask menu.

Typing the provider's name into an ordinary Siri conversation did not reliably route to the extension. Explicit selection in Spotlight is the path verified above. The localhost smoke test remains a separate diagnostic for the bridge and Claude account.

## Useful diagnostics

```sh
pluginkit -m -A -D -v -i dev.goldengate.Claude.Provider
codesign -d --entitlements - "$HOME/Applications/Claude.app"
codesign -d --entitlements - "$HOME/Applications/Claude.app/Contents/Extensions/ClaudeProvider.appex"
log show --last 5m --style compact --info \
  --predicate 'subsystem == "com.apple.externalproviderservice" AND eventMessage CONTAINS[c] "goldengate"'
```

Look for `Adding AgentIntent provider`, `Skipping`, and the provider's `isHidden` / `isAppAvailableForUse` fields. App Intents database queries used during the investigation were read-only; no system metadata database was edited. Locally extracted disassembly, temporary probe binaries, preference backups, and bearer tokens are excluded from Git.
