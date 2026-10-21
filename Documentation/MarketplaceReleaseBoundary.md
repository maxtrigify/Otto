# Marketplace release boundary

Marketplace is unfinished and is not exposed in the current app release. The Settings tab, Chat sidebar entry, bot-details action and onboarding promotion have been removed. Bot creation and details direct people to their provider's settings for additional integrations.

This is a presentation change. Provider connections, authentication, installed apps, MCP configuration, catalog models and installers are retained so existing integrations continue working. Do not delete saved connections or credentials as part of this cleanup.

`MarketplaceView` and its catalog remain available through the DEBUG-only `--apps-preview` launch argument for development. There is no production entry point. Reintroducing Marketplace should include a readiness review of installation, authentication, provider/account routing and failure states before restoring navigation or promotional copy.

Verification: build the Otto product; run `HarnessPluginCatalogTests`; visually check that Settings and Chat navigation have no Marketplace entry and Models settings still opens.
